#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <iostream>
#include <sstream>
#include <complex>

#include <quda_internal.h>
#include <color_spinor_field.h>
#include <blas_quda.h>
#include <dslash_quda.h>
#include <invert_quda.h>
#include <util_quda.h>
#include <eigen_helper.h>

// Use an implementation of the MinRes portion of BiCGstab-L which explicitly
// matches what's described in the original paper --- the non-legacy (default)
// path uses a BLAS-3 approach to MinRes which is empirically a bit less
// stable (in terms of iteration count) but more than compensates for that
// with improved time-to-solution
// #define LEGACY_MR

namespace quda {

#ifndef LEGACY_MR
  // Compute the MR portion of BiCGstab-L
  void BiCGstabL::computeMR(ColorSpinorField &x_sloppy, bool fixed_iteration)
  {
    using matrix = Matrix<std::complex<double>, Dynamic, Dynamic, RowMajor>;
    using vector = Matrix<std::complex<double>, Dynamic, 1>;

    // Compute gamma: minimize ||r - R \gamma||, where R is an L x R matrix
    // of r_1, r_2, ...
    // This requires computing R^dagger R and inverting it against R^dagger r_0,
    // which is solving the least squares problem in gamma. We pack this
    // into one fused block-blas by doing a fused calculation of {r_0, R}^dagger x R
    std::vector<ColorSpinorField *> r_dagger_vec(n_krylov);
    for (int i = 0; i < n_krylov; i++) r_dagger_vec[i] = r[i + 1];

    std::vector<ColorSpinorField *> r_vec(n_krylov + 1);
    for (int i = 0; i <= n_krylov; i++) r_vec[i] = r[i];

    Complex r_dagger_dot_r[(n_krylov + 1) * n_krylov];

    blas::cDotProduct(r_dagger_dot_r, r_dagger_vec, r_vec);

    matrix R_dag_R(n_krylov, n_krylov);
    vector R_dag_r0(n_krylov);

    for (int i = 0; i < n_krylov; i++) {
      for (int j = 0; j < n_krylov; j++) { R_dag_R(i, j) = r_dagger_dot_r[i * (n_krylov + 1) + (j + 1)]; }
      R_dag_r0(i) = r_dagger_dot_r[i * (n_krylov + 1)];
    }

    if (!param.is_preconditioner) {
      profile.TPSTOP(QUDA_PROFILE_COMPUTE);
      param.secs += profile.Last(QUDA_PROFILE_COMPUTE);
      profile.TPSTART(QUDA_PROFILE_EIGEN);
    }

    // Compute LDL decomposition, solve least squares problem for gamma
    Eigen::LDLT<matrix> ldlt;
    ldlt.compute(R_dag_R);
    vector gamma = ldlt.solve(R_dag_r0);

    if (!param.is_preconditioner) {
      profile.TPSTOP(QUDA_PROFILE_EIGEN);
      param.secs += profile.Last(QUDA_PROFILE_EIGEN);
      profile.TPSTART(QUDA_PROFILE_COMPUTE);
    }

    // Update omega for the next BiCG iteration
    omega = gamma(n_krylov - 1);

    std::vector<Complex> gamma_(n_krylov);

    if (!fixed_iteration) {

      // update u
      {
        // u = u[0] - \sum_{j=1}^L \gamma_L u_L
        for (int i = 0; i < n_krylov; i++) { gamma_[i] = -gamma(i); }

        std::vector<ColorSpinorField *> u_(u.begin() + 1, u.end());
        std::vector<ColorSpinorField *> u0(u.begin(), u.begin() + 1);

        blas::caxpy(gamma_.data(), u_, u0);
      }

      // update x and r
      {
        // x = x[0] + \sum_{j=1}^L \gamma_L r_{L-1}
        // r = r[0] - \sum_{j=1}^L \gamma_L r_L
        // we see that if we're a bit clever with zero padding we can
        // reuse r between the two updates.
        std::vector<Complex> gamma_for_x(n_krylov + 1);
        for (int i = 0; i < n_krylov; i++) gamma_for_x[i] = gamma(i);
        gamma_for_x[n_krylov] = 0; // do not want to update with last r

        std::vector<Complex> gamma_for_r(n_krylov + 1);
        gamma_for_r[0] = 0; // do not want to update with first r
        for (int i = 0; i < n_krylov; i++) gamma_for_r[i + 1] = -gamma(i);

        blas::caxpyBxpz(gamma_for_x.data(), r, x_sloppy, gamma_for_r.data(), *r[0]);
      }
    } else {
      // fixed iteration, only need to update x
      for (int i = 0; i < n_krylov; i++) { gamma_[i] = gamma(i); }

      std::vector<ColorSpinorField *> r_(r.begin(), r.end() - 1);
      std::vector<ColorSpinorField *> x_sloppy_(1);
      x_sloppy_[0] = &x_sloppy;

      blas::caxpy(gamma_.data(), r_, x_sloppy_);
    }
  }

  void BiCGstabL::computeTau(int, int, int)
  {
    errorQuda("Legacy MR path in BiCGstab-L called with a non-legacy compile");
  }

  void BiCGstabL::updateR(int, int, int) { errorQuda("Legacy MR path in BiCGstab-L called with a non-legacy compile"); }

  void BiCGstabL::legacyComputeMR(ColorSpinorField &)
  {
    errorQuda("Legacy MR path in BiCGstab-L called with a non-legacy compile");
  }

#else

  void BiCGstabL::computeMR(ColorSpinorField &, bool)
  {
    errorQuda("Non-legacy MR path in BiCGstab-L called with a legacy compile");
  }

  // Utility functions for Gram-Schmidt. Based on GCR functions.
  // Big change is we need to go from 1 to n_krylov, not 0 to n_krylov-1.
  void BiCGstabL::computeTau(int begin, int size, int j)
  {
    std::vector<Complex> Tau(size);
    std::vector<ColorSpinorField *> a(size), b(1);
    for (int k=0; k<size; k++)
    {
      a[k] = r[begin + k];
      Tau[k] = 0;
    }
    b[0] = r[j];
    blas::cDotProduct(Tau.data(), a, b); // vectorized dot product

    for (int k = 0; k < size; k++) { tau[(begin + k) * (n_krylov + 1) + j] = Tau[k] / sigma[begin + k]; }
  }

  void BiCGstabL::updateR(int begin, int size, int j)
  {
    std::vector<Complex> tau_(size);
    for (int i = 0; i < size; i++) { tau_[i] = -tau[(i + begin) * (n_krylov + 1) + j]; }

    std::vector<ColorSpinorField *> r_(r.begin() + begin, r.begin() + begin + size);
    std::vector<ColorSpinorField*> rj(r.begin() + j, r.begin() + j + 1);

    blas::caxpy(tau_.data(), r_, rj);
  }

  /**
     Legacy routine for the original pipelined Gram-Schmit
     See "The MR part" in https://etna.math.kent.edu/vol.1.1993/pp11-32.dir/pp11-32.pdf
   */
  void BiCGstabL::legacyComputeMR(ColorSpinorField &x_sloppy)
  {
    // MR part. Really just modified Gram-Schmidt.
    // The algorithm uses the byproducts of the Gram-Schmidt to update x
    // Can take this from 'orthoDir' in inv_gcr_quda.cpp, hard code pipelining up to l = 8.
    for (int j = 1; j <= n_krylov; j++) {

      // Perform a (pipelined) orthogonalization of r_j against r_{1 ... j-1}
      {
        switch (pipeline) {
        case 0:                       // no kernel fusion
          for (int i = 1; i < j; i++) // 5 (j-2) memory transactions here. Start at 1 b/c bicgstabl convention.
          {
            tau[i * (n_krylov + 1) + j] = blas::cDotProduct(*r[i], *r[j]) / sigma[i];
            blas::caxpy(-tau[i * (n_krylov + 1) + j], *r[i], *r[j]);
          }
          break;
        case 1:       // basic kernel fusion
          if (j == 1) // start at 1.
          {
            break;
          }
          tau[1 * (n_krylov + 1) + j] = blas::cDotProduct(*r[1], *r[j]) / sigma[1];
          for (int i = 1; i < j - 1; i++) // 4 (j-2) memory transactions here. start at 1.
          {
            tau[(i + 1) * (n_krylov + 1) + j]
              = blas::caxpyDotzy(-tau[i * (n_krylov + 1) + j], *r[i], *r[j], *r[i + 1]) / sigma[i + 1];
          }
          blas::caxpy(-tau[(j - 1) * (n_krylov + 1) + j], *r[j - 1], *r[j]);
          break;
        default: {
          const int N = pipeline;
          // We're orthogonalizing r[j] against r[1], ..., r[j-1].
          // We need to do (j-1)/N updates of length N, at 1,1+N,1+2*N,...
          // After, we do 1 update of length (j-1)%N.

          // (j-1)/N updates of length N, at 1,1+N,1+2*N,...
          int step;
          for (step = 0; step < (j - 1) / N; step++) {
            computeTau(1 + step * N, N, j);
            updateR(1 + step * N, N, j);
          }

          if ((j - 1) % N != 0) // need to update the remainder
          {
            // 1 update of length (j-1)%N.
            computeTau(1 + step * N, (j - 1) % N, j);
            updateR(1 + step * N, (j - 1) % N, j);
          }
        } break;
        }
      }

      // sigma_j = r_j^2, gamma'_j = <r_0, r_j>/sigma_j
      // rjr.x = Re(<r[j],r[0]), rjr.y = Im(<r[j],r[0]>), rjr.z = <r[j],r[j]>
      double3 rjr = blas::cDotProductNormA(*r[j], *r[0]);
      sigma[j] = rjr.z;
      gamma_prime[j] = Complex(rjr.x, rjr.y) / sigma[j];
    }

    // gamma[n_krylov] = gamma'[n_krylov], omega = gamma[n_krylov]
    gamma[n_krylov] = gamma_prime[n_krylov];
    omega = gamma[n_krylov];

    // gamma = T^(-1) gamma_prime. It's in the paper, I promise.
    for (int j = n_krylov - 1; j > 0; j--) {
      // Internal def: gamma[j] = gamma'_j - \sum_{i = j+1 to n_krylov} tau_ji gamma_i
      gamma[j] = gamma_prime[j];
      for (int i = j + 1; i <= n_krylov; i++) { gamma[j] = gamma[j] - tau[j * (n_krylov + 1) + i] * gamma[i]; }
    }

    // gamma'' = T S gamma. Check paper for defn of S.
    for (int j = 1; j < n_krylov; j++) {
      gamma_prime_prime[j] = gamma[j + 1];
      for (int i = j + 1; i < n_krylov; i++) {
        gamma_prime_prime[j] = gamma_prime_prime[j] + tau[j * (n_krylov + 1) + i] * gamma[i + 1];
      }
    }

    // Update x, r, u.
    // x = x+ gamma_1 r_0, r_0 = r_0 - gamma'_l r_l, u_0 = u_0 - gamma_l u_l, where l = n_krylov.

    // Update U
    {
      std::vector<Complex> gamma_(n_krylov);
      for (int i = 0; i < n_krylov; i++) { gamma_[i] = -gamma[i + 1]; }

      std::vector<ColorSpinorField *> u_(u.begin() + 1, u.end());
      std::vector<ColorSpinorField *> u0(u.begin(), u.begin() + 1);

      blas::caxpy(gamma_.data(), u_, u0);
    }

    // Update X and R, which has opportunities for reuse
    {
      // This does two "wasted" caxpys (so 2*n_krylov+2 instead of 2*n_kKrylov), but
      // the alternative way would be un-fusing some calls, which would require
      // loading and saving x twice. In a solve where the sloppy precision is lower than
      // the full precision, this can be a killer.
      std::vector<Complex> gamma_prime_prime_(n_krylov + 1);
      std::vector<Complex> gamma_prime_(n_krylov + 1);
      gamma_prime_prime_[0] = gamma[1];
      gamma_prime_prime_[n_krylov] = 0.0; // x never gets updated with r[n_krylov]
      gamma_prime_[0] = 0.0;              // r[0] never gets updated with r[0]... obvs.
      gamma_prime_[n_krylov] = -gamma_prime[n_krylov];
      for (int i = 1; i < n_krylov; i++) {
        gamma_prime_prime_[i] = gamma_prime_prime[i];
        gamma_prime_[i] = -gamma_prime[i];
      }
      blas::caxpyBxpz(gamma_prime_prime_.data(), r, x_sloppy, gamma_prime_.data(), *r[0]);
    }
  }

#endif // ifndef LEGACY_MR

  /**
     The following code is based on Kate's worker class in Multi-CG.

     This worker class is used to update most of the u and r vectors.
     On BiCG iteration j, r[0] through r[j] and u[0] through u[j]
     all get updated, but the subsequent mat-vec operation only gets
     applied to r[j] and u[j]. Thus, we can hide updating r[0] through
     r[j-1] and u[0] through u[j-1], respectively, in the comms for
     the matvec on r[j] and u[j]. This results in improved strong
     scaling for BiCGstab-L.

     See paragraphs 2 and 3 in the comments on the Worker class in
     Multi-CG for more remarks.
   */
  enum BiCGstabLUpdateType { BICGSTABL_UPDATE_U = 0, BICGSTABL_UPDATE_R = 1 };

  class BiCGstabLUpdate : public Worker {

    ColorSpinorField* x;
    std::vector<ColorSpinorField*> &r;
    std::vector<ColorSpinorField*> &u;

    Complex &alpha;
    Complex &beta;

    BiCGstabLUpdateType update_type;
    
    /**
       On a BiCG iteration j, u[0] through u[j-1] need to get updated,
       similarly r[0] through r[j-1] need to get updated. j_max = j.
     */
    int j_max;

    /**
       How much to partition the shifted update. For now, we assume
       we always need to partition into two pieces (since BiCGstab-L
       should only be getting even/odd preconditioned operators).
    */
    int n_update; 

  public:
    BiCGstabLUpdate(ColorSpinorField *x, std::vector<ColorSpinorField *> &r, std::vector<ColorSpinorField *> &u,
                    Complex &alpha, Complex &beta, BiCGstabLUpdateType update_type, int j_max, int n_update) :
      x(x), r(r), u(u), alpha(alpha), beta(beta), update_type(update_type), j_max(j_max), n_update(n_update)
    {
      
    }
    virtual ~BiCGstabLUpdate() { }
    
    void update_j_max(int new_j_max) { j_max = new_j_max; }
    void update_update_type(BiCGstabLUpdateType new_update_type) { update_type = new_update_type; }
    
    // note that we can't set the stream parameter here so it is
    // ignored.  This is more of a future design direction to consider
    void apply(const qudaStream_t = device::get_default_stream())
    {
      static int count = 0;

      // on the first call do the first half of the update
      if (update_type == BICGSTABL_UPDATE_U)
      {
        for (int i = (count * j_max) / n_update; i < ((count + 1) * j_max) / n_update && i < j_max; i++) {
          blas::caxpby(1.0, *r[i], -beta, *u[i]);
        }
      }
      else // (update_type == BICGSTABL_UPDATE_R)
      {
        if (count == 0) { blas::caxpy(alpha, *u[0], *x); }
        if (j_max > 0)
        {
          for (int i= (count*j_max)/n_update; i<((count+1)*j_max)/n_update && i<j_max; i++)
          {
            blas::caxpy(-alpha, *u[i + 1], *r[i]);
          }
        }
      }
      
      if (++count == n_update) count = 0;
    }
  };

  // this is the Worker pointer that the dslash uses to launch the shifted updates
  namespace dslash {
    extern Worker* aux_worker;
  }

  BiCGstabL::BiCGstabL(const DiracMatrix &mat, const DiracMatrix &matSloppy, const DiracMatrix &matEig,
                       SolverParam &param, TimeProfile &profile) :
    Solver(mat, matSloppy, matSloppy, matEig, param, profile),
    matMdagM(matEig.Expose()),
    n_krylov(param.Nkrylov),
    init(false)
  {
    r.resize(n_krylov + 1);
    u.resize(n_krylov + 1);

    gamma.resize(n_krylov + 1);
    gamma_prime.resize(n_krylov + 1);
    gamma_prime_prime.resize(n_krylov + 1);
    sigma.resize(n_krylov + 1);

    tau.resize((n_krylov + 1) * (n_krylov + 1));

    std::stringstream ss;
    ss << "BiCGstab-" << n_krylov;
    solver_name = ss.str();
  }

  BiCGstabL::~BiCGstabL()
  {
    profile.TPSTART(QUDA_PROFILE_FREE);

    if (init) {
      delete r_sloppy_saved_p;
      delete u[0];
      for (int i = 1; i < n_krylov + 1; i++) {
        delete r[i];
        delete u[i];
      }

      delete x_sloppy_saved_p;
      delete r0_saved_p;

      init = false;
    }

    destroyDeflationSpace();

    profile.TPSTOP(QUDA_PROFILE_FREE);
  }

  // Code to check for reliable updates, copied from inv_bicgstab_quda.cpp
  // Technically, there are ways to check both 'x' and 'r' for reliable updates...
  // the current status in BiCGstab is to just look for reliable updates in 'r'.
  int BiCGstabL::reliable(double &rNorm, double &maxrx, double &maxrr, const double &r2, const double &delta) {
    // reliable updates
    rNorm = sqrt(r2);
    if (rNorm > maxrx) maxrx = rNorm;
    if (rNorm > maxrr) maxrr = rNorm;
    //int updateR = (rNorm < delta*maxrr && r0Norm <= maxrr) ? 1 : 0;
    //int updateX = (rNorm < delta*r0Norm && r0Norm <= maxrx) ? 1 : 0
    int updateR = (rNorm < delta*maxrr) ? 1 : 0;
    
    //printf("reliable %d %e %e %e %e\n", updateR, rNorm, maxrx, maxrr, r2);

    return updateR;
  }

  void BiCGstabL::operator()(ColorSpinorField &x, ColorSpinorField &b) 
  {
    // BiCGstab-l is based on the algorithm outlined in
    // BICGSTAB(L) FOR LINEAR EQUATIONS INVOLVING UNSYMMETRIC MATRICES WITH COMPLEX SPECTRUM
    // G. Sleijpen, D. Fokkema, 1993.
    // My implementation is based on Kate Clark's implementation in CPS, to be found in
    // src/util/dirac_op/d_op_wilson_types/bicgstab.C
    
    // Begin profiling preamble.
    profile.TPSTART(QUDA_PROFILE_PREAMBLE);
    
    if (!init) {
      // Initialize fields.
      ColorSpinorParam csParam(x);
      csParam.create = QUDA_ZERO_FIELD_CREATE;
      
      // Full precision variables.
      r_fullp = std::make_unique<ColorSpinorField>(csParam);

      // Create temporary.
      yp = std::make_unique<ColorSpinorField>(csParam);

      // Sloppy precision variables.
      csParam.setPrecision(param.precision_sloppy); 
      
      // Sloppy solution.
      x_sloppy_saved_p = ColorSpinorField::Create(csParam); // Used depending on precision.
      
      // Shadow residual.
      r0_saved_p = ColorSpinorField::Create(csParam); // Used depending on precision. 
      
      // Temporary
      tempp = std::make_unique<ColorSpinorField>(csParam);

      // Residual (+ extra residuals for BiCG steps), Search directions.
      // Remark: search directions are sloppy in GCR. I wonder if we can
      //           get away with that here.
      for (int i = 0; i <= n_krylov; i++) {
        r[i] = ColorSpinorField::Create(csParam);
        u[i] = ColorSpinorField::Create(csParam);
      }
      r_sloppy_saved_p = r[0]; // Used depending on precision. 
      
      init = true; 
    }

    // compute b2, but only if we need to
    bool fixed_iteration = param.sloppy_converge && n_krylov == param.maxiter && !param.compute_true_res;
    double b2 = !fixed_iteration ? blas::norm2(b) : 1.0; // norm sq of source.
    double r2;                  // norm sq of residual
    
    ColorSpinorField &r_full = *r_fullp;
    ColorSpinorField &y = *yp;
    ColorSpinorField &temp = *tempp;

    ColorSpinorField *r0p, *x_sloppyp; // Get assigned below.

    if (param.deflate) {
      // Construct the eigensolver and deflation space if requested.
      if (param.eig_param.eig_type == QUDA_EIG_TR_LANCZOS || param.eig_param.eig_type == QUDA_EIG_BLK_TR_LANCZOS) {
        constructDeflationSpace(b, matMdagM);
      } else {
        // Use Arnoldi to inspect the space only and turn off deflation
        constructDeflationSpace(b, mat);
        param.deflate = false;
      }
      if (deflate_compute) {
        // compute the deflation space.
        if (!param.is_preconditioner) profile.TPSTOP(QUDA_PROFILE_PREAMBLE);
        (*eig_solve)(evecs, evals);
        if (param.deflate) {
          // double the size of the Krylov space
          extendSVDDeflationSpace();
          // populate extra memory with L/R singular vectors
          eig_solve->computeSVD(matMdagM, evecs, evals);
        }
        if (!param.is_preconditioner) profile.TPSTART(QUDA_PROFILE_PREAMBLE);
        deflate_compute = false;
      }
      if (recompute_evals) {
        eig_solve->computeEvals(matMdagM, evecs, evals);
        eig_solve->computeSVD(matMdagM, evecs, evals);
        recompute_evals = false;
      }
    }

    // Compute initial residual depending on whether we have an initial guess or not.
    if (param.use_init_guess == QUDA_USE_INIT_GUESS_YES) {
      mat(r_full, x, y); // r[0] = Ax
      if (!fixed_iteration) {
        r2 = blas::xmyNorm(b, r_full); // r = b - Ax, return norm.
      } else {
        blas::xpay(b, -1.0, r_full);
        r2 = b2; // dummy setting
      }
      blas::copy(y, x); // we accumulate into y
    } else {
      blas::copy(r_full, b); // r[0] = b
      r2 = b2;
      blas::zero(x); // defensive measure in case solution isn't already zero
      blas::zero(y);
    }

    if (param.deflate && param.maxiter > 1) {
      // Deflate: Hardcoded to SVD. If maxiter == 1, this is a dummy solve
      eig_solve->deflateSVD(x, r_full, evecs, evals, true);

      // Compute r_defl = RHS - A * LHS
      mat(r_full, x, temp);
      if (!fixed_iteration) {
        r2 = blas::xmyNorm(b, r_full);
      } else {
        blas::xpay(b, -1.0, r_full);
        r2 = b2; // dummy setting
      }
      blas::copy(y, x);
    }

    // Check to see that we're not trying to invert on a zero-field source
    if (b2 == 0) {
      if (param.compute_null_vector == QUDA_COMPUTE_NULL_VECTOR_NO) {
        warningQuda("inverting on zero-field source");
        x = b;
        param.true_res = 0.0;
        param.true_res_hq = 0.0;
        profile.TPSTOP(QUDA_PROFILE_PREAMBLE);
        return;
      } else if (param.use_init_guess == QUDA_USE_INIT_GUESS_YES) {
        b2 = r2;
      } else {
        errorQuda("Null vector computing requires non-zero guess!");
      }
    }

    // Set field aliasing according to whether we're doing mixed precision or not.
    // There probably be bugs and headaches hiding here.
    if (param.precision_sloppy == x.Precision()) {
      r[0] = &r_full; // r[0] \equiv r_sloppy points to the same memory location as r.
      if (param.compute_null_vector == QUDA_COMPUTE_NULL_VECTOR_NO)
      {
        r0p = &b; // r0, b point to the same vector in memory.
      }
      else
      {
        r0p = r0_saved_p; // r0p points to the saved r0 memory.
        *r0p = r_full; // and is set equal to r.
      }
    }
    else
    {
      r0p = r0_saved_p; // r0p points to saved r0 memory.
      r[0] = r_sloppy_saved_p; // r[0] points to saved r_sloppy memory.
      *r0p = r_full; // and is set equal to r.
      *r[0] = r_full; // yup.
    }
    
    if (param.precision_sloppy == x.Precision() || !param.use_sloppy_partial_accumulator) 
    {
      x_sloppyp = &x; // x_sloppy and x point to the same vector in memory.
      blas::zero(*x_sloppyp); // x_sloppy is zeroed out (and, by extension, so is x).
    }
    else
    {
      x_sloppyp = x_sloppy_saved_p; // x_sloppy point to saved x_sloppy memory.
      blas::zero(*x_sloppyp); // and is zeroed out. 
    }
    
    // Syntatic sugar.
    ColorSpinorField &r0 = *r0p;
    ColorSpinorField &x_sloppy = *x_sloppyp;
    
    // Zero out the first search direction. 
    blas::zero(*u[0]);
    
    
    // Set some initial values.
    sigma[0] = blas::norm2(r_full);
    

    // Initialize values.
    for (int i = 1; i <= n_krylov; i++) { blas::zero(*r[i]); }

    rho0 = 1.0;
    alpha = 0.0;
    omega = 1.0;

    double stop = !fixed_iteration ? stopping(param.tol, b2, param.residual_type) : 0.0; // stopping condition of solver.

    const bool use_heavy_quark_res = 
      (param.residual_type & QUDA_HEAVY_QUARK_RESIDUAL) ? true : false;
    double heavy_quark_res = use_heavy_quark_res ? sqrt(blas::HeavyQuarkResidualNorm(x,r_full).z) : 0.0;
    const int heavy_quark_check = param.heavy_quark_check; // how often to check the heavy quark residual
    
    blas::flops = 0;
    //bool l2_converge = false;
    //double r2_old = r2;

    pipeline = param.pipeline;

    // Create the worker class for updating non-critical r, u vectors.
    BiCGstabLUpdate bicgstabl_update(&x_sloppy, r, u, alpha, beta, BICGSTABL_UPDATE_U, 0, matSloppy.getStencilSteps());

    // done with preamble, begin computing.
    profile.TPSTOP(QUDA_PROFILE_PREAMBLE);
    profile.TPSTART(QUDA_PROFILE_COMPUTE);

    // count iteration counts
    int total_iter = 0;

    // Various variables related to reliable updates.
    int rUpdate = 0; // count reliable updates. 
    double delta = param.delta; // delta for reliable updates. 
    double rNorm = sqrt(r2); // The current residual norm. 
    double maxrr = rNorm; // The maximum residual norm since the last reliable update.
    double maxrx = rNorm; // The same. Would be different if we did 'x' reliable updates.

    PrintStats(solver_name.c_str(), total_iter, r2, b2, heavy_quark_res);
    while (!convergence(r2, 0.0, stop, 0.0) && total_iter < param.maxiter) {

      // rho0 = -omega*rho0;
      rho0 *= -omega;

      // BiCG part of calculation.
      for (int j = 0; j < n_krylov; j++) {
        // rho1 = <r0, r_j>, beta = alpha*rho1/rho0, rho0 = rho1;
        // Can fuse into updateXRend.
        rho1 = blas::cDotProduct(r0, *r[j]);
        beta = alpha*rho1/rho0;
        rho0 = rho1;

        // for i = 0 .. j, u[i] = r[i] - beta*u[i]
        // All but i = j is hidden in Dslash auxillary work (overlapping comms and compute).
        blas::caxpby(1.0, *r[j], -beta, *u[j]);
        if (j > 0)
        {
          dslash::aux_worker = &bicgstabl_update;
          bicgstabl_update.update_j_max(j);
          bicgstabl_update.update_update_type(BICGSTABL_UPDATE_U);
        } else {
          dslash::aux_worker = NULL;
        }

        // u[j+1] = A ( u[j] )
        matSloppy(*u[j+1], *u[j], temp);
        
        // alpha = rho0/<r0, u[j+1]>
        // The machinary isn't there yet, but this could be fused with the matSloppy above.
        alpha = rho0/blas::cDotProduct(r0, *u[j+1]);

        // for i = 0 .. j, r[i] = r[i] - alpha u[i+1]
        // All but i = j is hidden in Dslash auxillary work (overlapping comms and compute).
        blas::caxpy(-alpha, *u[j+1], *r[j]);
        // We can always at least update x.
        dslash::aux_worker = &bicgstabl_update;
        bicgstabl_update.update_j_max(j);
        bicgstabl_update.update_update_type(BICGSTABL_UPDATE_R);
        
        // r[j+1] = A r[j], x = x + alpha*u[0]
        matSloppy(*r[j+1], *r[j], temp);
        dslash::aux_worker = NULL;

      } // End BiCG part.

#ifndef LEGACY_MR
      // Perform the MR portion of BiCGstab-L
      // if we're doing a fixed number of iterations, we only need to update x
      computeMR(x_sloppy, fixed_iteration);
#else
      // Legacy version matching the BiCGstab-L paper which performs
      // an explicit Gram-Schmidt for the MR portion
      legacyComputeMR(x_sloppy);
#endif

      if (!fixed_iteration) {
        // sigma[0] = r_0^2
        sigma[0] = blas::norm2(*r[0]);
        r2 = sigma[0];

        // Check the heavy quark residual if we need to.
        if (use_heavy_quark_res && total_iter % heavy_quark_check == 0) {
          if (&x != &x_sloppy) {
            blas::copy(temp, y);
            heavy_quark_res = sqrt(blas::xpyHeavyQuarkResidualNorm(x_sloppy, temp, *r[0]).z);
          } else {
            blas::copy(r_full, *r[0]);
            heavy_quark_res = sqrt(blas::xpyHeavyQuarkResidualNorm(x, y, r_full).z);
          }
        }
      }

      // Check if we need to do a reliable update.
      // In inv_bicgstab_quda.cpp, there's a variable 'updateR' that holds the check.
      // That variable gets carried about because there are a few different places 'r' can get
      // updated (depending on if you're using pipelining or not). In BiCGstab-L, there's only
      // one place (for now) to get the updated residual, so we just do away with 'updateR'.
      // Further remark: "reliable" updates rNorm, maxrr, maxrx!!
      if (total_iter >= param.maxiter || r2 < stop || reliable(rNorm, maxrx, maxrr, r2, delta)) {
        if ((r2 < stop || total_iter >= param.maxiter) && param.sloppy_converge) break;

        if (x.Precision() != x_sloppy.Precision()) { blas::copy(x, x_sloppy); }

        blas::xpy(x, y);

        // Don't do aux work!
        dslash::aux_worker = NULL;

        // Explicitly recompute the residual.
        mat(r_full, y, x); // r[0] = Ax

        r2 = blas::xmyNorm(b, r_full); // r = b - Ax, return norm.
        
        sigma[0] = r2;
        
        if (x.Precision() != r[0]->Precision())
        {
          blas::copy(*r[0], r_full);
        }
        blas::zero(x_sloppy);

        // Update rNorm, maxrr, maxrx.
        rNorm = sqrt(r2);
        maxrr = rNorm;
        maxrx = rNorm;
        
        // Increment the reliable update count.
        rUpdate++;
      }

      // Check convergence.
      total_iter += n_krylov;
      PrintStats(solver_name.c_str(), total_iter, r2, b2, heavy_quark_res);
    } // Done iterating.

    if (x.Precision() != x_sloppy.Precision())
    {
      blas::copy(x, x_sloppy);
    }

    blas::xpy(y, x);

    // Done with compute, begin the epilogue.
    profile.TPSTOP(QUDA_PROFILE_COMPUTE);
    profile.TPSTART(QUDA_PROFILE_EPILOGUE);

    param.secs += profile.Last(QUDA_PROFILE_COMPUTE);
    double gflops = (blas::flops + mat.flops() + matSloppy.flops() + matEig.flops()) * 1e-9;
    param.gflops = gflops;
    param.iter += total_iter;

    if (total_iter >= param.maxiter) // >= if n_krylov doesn't divide max iter.
      warningQuda("Exceeded maximum iterations %d", param.maxiter);

    // Print number of reliable updates.
    if (getVerbosity() >= QUDA_VERBOSE) printfQuda("%s: Reliable updates = %d\n", solver_name.c_str(), rUpdate);

    // compute the true residual
    // !param.is_preconditioner comes from bicgstab, param.compute_true_res came from gcr.
    if (!param.is_preconditioner && param.compute_true_res) { // do not do the below if this is an inner solver.
      mat(r_full, x, y);
      double true_res = blas::xmyNorm(b, r_full);
      param.true_res = sqrt(true_res / b2);
      
      param.true_res_hq = use_heavy_quark_res ? sqrt(blas::HeavyQuarkResidualNorm(x,*r[0]).z) : 0.0;
    }

    // Reset flops counters.
    blas::flops = 0;
    mat.flops();
    
    // copy the residual to b so we can use it outside of the solver.
    if (param.preserve_source == QUDA_PRESERVE_SOURCE_NO) { blas::copy(b, r_full); }

    // Done with epilogue, begin free.

    profile.TPSTOP(QUDA_PROFILE_EPILOGUE);
    param.secs += profile.Last(QUDA_PROFILE_EPILOGUE);
    profile.TPSTART(QUDA_PROFILE_FREE);
    
    // ...yup...
    PrintSummary(solver_name.c_str(), total_iter, r2, b2, stop, param.tol_hq);

    // Done!
    profile.TPSTOP(QUDA_PROFILE_FREE);
    return;
  }

} // namespace quda
