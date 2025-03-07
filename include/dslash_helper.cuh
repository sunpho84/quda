#pragma once

#include <color_spinor_field.h>
#include <gauge_field.h>
#include <register_traits.h>
#include <index_helper.cuh>
#include <shmem_helper.cuh>
#include <fast_intdiv.h>
#include <dslash_quda.h>

#if defined(_NVHPC_CUDA)
#include <constant_kernel_arg.h>
constexpr bool use_kernel_arg = false;
#else
constexpr bool use_kernel_arg = true;
#endif

#include <kernel.h>

namespace quda
{
  /**
     @brief Helper function to determine if we should do halo
     computation
     @param[in] dim Dimension we are working on.  If dim=-1 (default
     argument) then we return true if type is any halo kernel.
  */
  template <KernelType type> __host__ __device__ __forceinline__ bool doHalo(int dim = -1)
  {
    switch (type) {
    case EXTERIOR_KERNEL_ALL: return true;
    case EXTERIOR_KERNEL_X: return dim == 0 || dim == -1 ? true : false;
    case EXTERIOR_KERNEL_Y: return dim == 1 || dim == -1 ? true : false;
    case EXTERIOR_KERNEL_Z: return dim == 2 || dim == -1 ? true : false;
    case EXTERIOR_KERNEL_T: return dim == 3 || dim == -1 ? true : false;
    case INTERIOR_KERNEL: return false;
    }
    return false;
  }

  /**
     @brief Helper function to determine if we should do interior
     computation
     @param[in] dim Dimension we are working on
  */
  template <KernelType type> __host__ __device__ __forceinline__ bool doBulk()
  {
    switch (type) {
    case EXTERIOR_KERNEL_ALL:
    case EXTERIOR_KERNEL_X:
    case EXTERIOR_KERNEL_Y:
    case EXTERIOR_KERNEL_Z:
    case EXTERIOR_KERNEL_T: return false;
    case INTERIOR_KERNEL: return true;
    }
    return false;
  }

  /**
     @brief Helper functon to determine if the application of the
     derivative in the dslash is complete
     @param[in] Argument parameter struct
     @param[in] Checkerboard space-time index
     @param[in] Parity we are acting on
  */
  template <KernelType type, typename Arg, typename Coord>
  __host__ __device__ __forceinline__ bool isComplete(const Arg &arg, const Coord &coord)
  {
    int incomplete = 0; // Have all 8 contributions been computed for this site?

    switch (type) {                                      // intentional fall-through
    case EXTERIOR_KERNEL_ALL: incomplete = false; break; // all active threads are complete
    case INTERIOR_KERNEL:
      incomplete = incomplete || (arg.commDim[3] && (coord[3] == 0 || coord[3] == (arg.dc.X[3] - 1)));
    case EXTERIOR_KERNEL_T:
      incomplete = incomplete || (arg.commDim[2] && (coord[2] == 0 || coord[2] == (arg.dc.X[2] - 1)));
    case EXTERIOR_KERNEL_Z:
      incomplete = incomplete || (arg.commDim[1] && (coord[1] == 0 || coord[1] == (arg.dc.X[1] - 1)));
    case EXTERIOR_KERNEL_Y:
      incomplete = incomplete || (arg.commDim[0] && (coord[0] == 0 || coord[0] == (arg.dc.X[0] - 1)));
    case EXTERIOR_KERNEL_X: break;
    }

    return !incomplete;
  }

  /**
     @brief Compute the space-time coordinates we are at.
     @param[out] coord The computed space-time coordinates
     @param[in] arg DslashArg struct
     @param[in,out] idx Space-time index (usually equal to global
     x-thread index).  When doing EXTERIOR kernels we overwrite this
     with the index into our face (ghost index).
     @param[in] parity Field parity
     @param[out] the dimension we are working on (fused kernel only)
     @return checkerboard space-time index
  */
  template <QudaPCType pc_type, KernelType kernel_type, typename Arg, int nface_ = 1>
  __host__ __device__ inline auto getCoords(const Arg &arg, int &idx, int s, int parity, int &dim)
  {
    constexpr auto nDim = Arg::nDim;
    Coord<nDim> coord;
    dim = kernel_type; // keep compiler happy

    // only for 5-d checkerboarding where we need to include the fifth dimension
    const int Ls = (nDim == 5 && pc_type == QUDA_5D_PC ? (int)arg.dim[4] : 1);

    if (kernel_type == INTERIOR_KERNEL) {
      coord.x_cb = idx;
      if (nDim == 5)
        coord.X = getCoords5CB(coord, idx, arg.dim, arg.X0h, parity, pc_type);
      else
        coord.X = getCoordsCB(coord, idx, arg.dim, arg.X0h, parity);
    } else if (kernel_type != EXTERIOR_KERNEL_ALL) {

      // compute face index and then compute coords
      const int face_size = nface_ * arg.dc.ghostFaceCB[kernel_type] * Ls;
      const int face_num = idx >= face_size;
      idx -= face_num * face_size;
      coordsFromFaceIndex<nDim, pc_type, kernel_type, nface_>(coord.X, coord.x_cb, coord, idx, face_num, parity, arg);

    } else { // fused kernel

      // work out which dimension this thread corresponds to, then compute coords
      if (idx < arg.threadDimMapUpper[0] * Ls) { // x face
        dim = 0;
        const int face_size = nface_ * arg.dc.ghostFaceCB[dim] * Ls;
        const int face_num = idx >= face_size;
        idx -= face_num * face_size;
        coordsFromFaceIndex<nDim, pc_type, 0, nface_>(coord.X, coord.x_cb, coord, idx, face_num, parity, arg);
      } else if (idx < arg.threadDimMapUpper[1] * Ls) { // y face
        dim = 1;
        idx -= arg.threadDimMapLower[1] * Ls;
        const int face_size = nface_ * arg.dc.ghostFaceCB[dim] * Ls;
        const int face_num = idx >= face_size;
        idx -= face_num * face_size;
        coordsFromFaceIndex<nDim, pc_type, 1, nface_>(coord.X, coord.x_cb, coord, idx, face_num, parity, arg);
      } else if (idx < arg.threadDimMapUpper[2] * Ls) { // z face
        dim = 2;
        idx -= arg.threadDimMapLower[2] * Ls;
        const int face_size = nface_ * arg.dc.ghostFaceCB[dim] * Ls;
        const int face_num = idx >= face_size;
        idx -= face_num * face_size;
        coordsFromFaceIndex<nDim, pc_type, 2, nface_>(coord.X, coord.x_cb, coord, idx, face_num, parity, arg);
      } else { // t face
        dim = 3;
        idx -= arg.threadDimMapLower[3] * Ls;
        const int face_size = nface_ * arg.dc.ghostFaceCB[dim] * Ls;
        const int face_num = idx >= face_size;
        idx -= face_num * face_size;
        coordsFromFaceIndex<nDim, pc_type, 3, nface_>(coord.X, coord.x_cb, coord, idx, face_num, parity, arg);
      }
    }
    coord.s = s;
    return coord;
  }

  /**
     @brief Compute whether the provided coordinate is within the halo
     region boundary of a given dimension.

     @param[in] coord Coordinates
     @param[in] Arg Dslash argument struct
     @return True if in boundary, else false
  */
  template <int dim, typename Coord, typename Arg> inline __host__ __device__ bool inBoundary(const Coord &coord, const Arg &arg)
  {
    return ((coord[dim] >= arg.dim[dim] - arg.nFace) || (coord[dim] < arg.nFace));
  }

  /**
     @brief Compute whether this thread should be active for updating
     the a given offsetDim halo.  For non-fused halo update kernels
     this is a trivial kernel that just checks if the given dimension
     is partitioned and if so, return true.

     For fused halo region update kernels: here every thread has a
     prescribed dimension it is tasked with updating, but for the
     edges and vertices, the thread responsible for the entire update
     is the "greatest" one.  Hence some threads may be labelled as a
     given dimension, but they have to update other dimensions too.
     Conversely, a given thread may be labeled for a given dimension,
     but if that thread lies at en edge or vertex, and we have
     partitioned a higher dimension, then that thread will cede to the
     higher thread.

     @param[in,out] Whether this thread is "cumulatively" active
     (cumulative over all dimensions)
     @param[in] threadDim Prescribed dimension of this thread
     @param[in] offsetDim The dimension we are querying whether this
     thread should be responsible
     @param[in] offset The size of the hop
     @param[in] y Site coordinate
     @param[in] partitioned Array of which dimensions have been partitioned
     @param[in] X Lattice dimensions
     @return true if this thread is active
  */
  template <KernelType kernel_type, typename Coord, typename Arg>
  inline __device__ bool isActive(bool &active, int threadDim, int offsetDim, const Coord &coord, const Arg &arg)
  {
    // Threads with threadDim = t can handle t,z,y,x offsets
    // Threads with threadDim = z can handle z,y,x offsets
    // Threads with threadDim = y can handle y,x offsets
    // Threads with threadDim = x can handle x offsets
    if (!arg.commDim[offsetDim]) return false;

    if (kernel_type == EXTERIOR_KERNEL_ALL) {
      if (threadDim < offsetDim) return false;

      switch (threadDim) {
      case 3: // threadDim = T
        break;

      case 2: // threadDim = Z
        if (!arg.commDim[3]) break;
        if (arg.commDim[3] && inBoundary<3>(coord, arg)) return false;
        break;

      case 1: // threadDim = Y
        if ((!arg.commDim[3]) && (!arg.commDim[2])) break;
        if (arg.commDim[3] && inBoundary<3>(coord, arg)) return false;
        if (arg.commDim[2] && inBoundary<2>(coord, arg)) return false;
        break;

      case 0: // threadDim = X
        if ((!arg.commDim[3]) && (!arg.commDim[2]) && (!arg.commDim[1])) break;
        if (arg.commDim[3] && inBoundary<3>(coord, arg)) return false;
        if (arg.commDim[2] && inBoundary<2>(coord, arg)) return false;
        if (arg.commDim[1] && inBoundary<1>(coord, arg)) return false;
        break;

      default: break;
      }
    }

    active = true;
    return true;
  }

  template <typename Float_, int nDim_> struct DslashArg {

    using Float = Float_;
    using real = typename mapper<Float>::type;
    static constexpr int nDim = nDim_;

    const int parity;  // only use this for single parity fields
    const int nParity; // number of parities we're working on
    const int nFace;   // hard code to 1 for now
    const QudaReconstructType reconstruct;

    const int_fastdiv X0h;
    const int_fastdiv dim[5]; // full lattice dimensions
    const int volumeCB;       // checkerboarded volume
    int commDim[4];           // whether a given dimension is partitioned or not (potentially overridden for Schwarz)

    const bool dagger; // dagger
    const bool xpay;   // whether we are doing xpay or not

    DslashConstant dc;      // pre-computed dslash constants for optimized indexing
    KernelType kernel_type; // interior, exterior_t, etc.
    bool remote_write;      // used by the autotuner to switch on/off remote writing vs using copy engines

    int_fastdiv threads; // number of threads in x-thread dimension
    int_fastdiv exterior_threads; //  number of threads in x-thread dimension for fused exterior dslash
    int threadDimMapLower[4];
    int threadDimMapUpper[4];

    const bool spin_project; // whether to spin project nSpin=4 fields (generally true, except for, e.g., covariant derivative)

    // these are set with symmetric preconditioned twisted-mass dagger
    // operator for the packing (which needs to a do a twist)
    real twist_a; // scale factor
    real twist_b; // chiral twist
    real twist_c; // flavor twist

    int pack_threads; // really number of face sites we have to pack
    int_fastdiv blocks_per_dir;
    int sites_per_block;
    int dim_map[4];
    int active_dims;
    int pack_blocks; // total number of blocks used for packing in the dslash
    int exterior_dims; // dimension to run in the exterior Dslash
    int exterior_blocks;

    // for shmem ...
    static constexpr bool packkernel = false;
    void *packBuffer[4 * QUDA_MAX_DIM];
    int neighbor_ranks[2 * QUDA_MAX_DIM];
    int bytes[2 * QUDA_MAX_DIM];
#ifndef NVSHMEM_COMMS
    static constexpr int shmem = 0;
    dslash::shmem_sync_t counter = 0;
#else
    int shmem;
    dslash::shmem_sync_t counter;
    dslash::shmem_sync_t *sync_arr;
    dslash::shmem_interior_done_t &interior_done;
    dslash::shmem_interior_count_t &interior_count;
    dslash::shmem_retcount_intra_t *retcount_intra;
    dslash::shmem_retcount_inter_t *retcount_inter;
#endif

    // constructor needed for staggered to set xpay from derived class
    DslashArg(const ColorSpinorField &in, const GaugeField &U, int parity, bool dagger, bool xpay, int nFace,
              int spin_project, const int *comm_override,
#ifdef NVSHMEM_COMMS
              int shmem_ = 0) :
#else
              int = 0) :
#endif
      parity(parity),
      nParity(in.SiteSubset()),
      nFace(nFace),
      reconstruct(U.Reconstruct()),
      X0h(nParity == 2 ? in.X(0) / 2 : in.X(0)),
      dim {(3 - nParity) * in.X(0), in.X(1), in.X(2), in.X(3), in.Ndim() == 5 ? in.X(4) : 1},
      volumeCB(in.VolumeCB()),
      dagger(dagger),
      xpay(xpay),
      kernel_type(INTERIOR_KERNEL),
      threads(in.VolumeCB()),
      exterior_threads(0),
      threadDimMapLower {},
      threadDimMapUpper {},
      spin_project(spin_project),
      twist_a(0.0),
      twist_b(0.0),
      twist_c(0.0),
      pack_threads(0),
      blocks_per_dir(1),
      dim_map {},
      active_dims(0),
      pack_blocks(0),
      exterior_dims(0),
      exterior_blocks(0),
#ifndef NVSHMEM_COMMS
      counter(0)
#else
      shmem(shmem_),
      counter(dslash::get_shmem_sync_counter()),
      sync_arr(dslash::get_shmem_sync_arr()),
      interior_done(*dslash::get_shmem_interior_done()),
      interior_count(*dslash::get_shmem_interior_count()),
      retcount_intra(dslash::get_shmem_retcount_intra()),
      retcount_inter(dslash::get_shmem_retcount_inter())
#endif

    {
      for (int d = 0; d < 4; d++) {
        commDim[d] = (comm_override[d] == 0) ? 0 : comm_dim_partitioned(d);
      }

      if (in.Location() == QUDA_CUDA_FIELD_LOCATION) {
        // create comms buffers - need to do this before we grab the dslash constants
        const_cast<ColorSpinorField &>(in).createComms(nFace, spin_project);
      }
      dc = in.getDslashConstant();
      for (int dim = 0; dim < 4; dim++) {
        for (int dir = 0; dir < 2; dir++) {
          neighbor_ranks[2 * dim + dir] = commDim[dim] ? comm_neighbor_rank(dir, dim) : -1;
          bytes[2 * dim + dir] = in.GhostFaceBytes(dim);
        }
      }
    }

    void setPack(bool pack, void *packBuffer_[4 * QUDA_MAX_DIM])
    {
      if (pack) {
        // set packing parameters
        // for now we set one block per direction / dimension
        int d = 0;
        pack_threads = 0;
        for (int i = 0; i < 4; i++) {
          if (!commDim[i]) continue;
          pack_threads += 2 * nFace * dc.ghostFaceCB[i]; // 2 for fwd/back faces
          dim_map[d++] = i;
        }
        active_dims = d;
        pack_blocks = active_dims * blocks_per_dir * 2;
        for (int i = 0; i < 4 * QUDA_MAX_DIM; i++) { packBuffer[i] = packBuffer_[i]; }
      } else {
        // we need dim_map for the grid-stride exterior kernel used in shmem
        int d = 0;
        for (int i = 0; i < 4; i++) {
          if (!commDim[i]) continue;
          dim_map[d++] = i;
        }
        pack_threads = 0;
        pack_blocks = 0;
        active_dims = 0;
      }
    }

    void setExteriorDims(bool exterior)
    {
      if (exterior) {
        int nDimComms = 0;
        for (int d = 0; d < 4; d++) nDimComms += commDim[d];
        exterior_dims = nDimComms;
      } else {
        exterior_dims = 0;
      }
    }
  };

  template <typename Float, int nDim> std::ostream &operator<<(std::ostream &out, const DslashArg<Float, nDim> &arg)
  {
    out << "parity = " << arg.parity << std::endl;
    out << "nParity = " << arg.nParity << std::endl;
    out << "nFace = " << arg.nFace << std::endl;
    out << "reconstruct = " << arg.reconstruct << std::endl;
    out << "X0h = " << arg.X0h << std::endl;
    out << "dim = { ";
    for (int i = 0; i < 5; i++) out << arg.dim[i] << (i < 4 ? ", " : " }");
    out << std::endl;
    out << "commDim = { ";
    for (int i = 0; i < 4; i++) out << arg.commDim[i] << (i < 3 ? ", " : " }");
    out << std::endl;
    out << "volumeCB = " << arg.volumeCB << std::endl;
    out << "dagger = " << arg.dagger << std::endl;
    out << "xpay = " << arg.xpay << std::endl;
    out << "kernel_type = " << arg.kernel_type << std::endl;
    out << "remote_write = " << arg.remote_write << std::endl;
    out << "threads = " << arg.threads << std::endl;
    out << "threadDimMapLower = { ";
    for (int i = 0; i < 4; i++) out << arg.threadDimMapLower[i] << (i < 3 ? ", " : " }");
    out << std::endl;
    out << "threadDimMapUpper = { ";
    for (int i = 0; i < 4; i++) out << arg.threadDimMapUpper[i] << (i < 3 ? ", " : " }");
    out << std::endl;
    out << "twist_a = " << arg.twist_a << std::endl;
    out << "twist_b = " << arg.twist_b << std::endl;
    out << "twist_c = " << arg.twist_c << std::endl;
    out << "pack_threads = " << arg.pack_threads << std::endl;
    out << "blocks_per_dir = " << arg.blocks_per_dir << std::endl;
    out << "dim_map = { ";
    for (int i = 0; i < 4; i++) out << arg.dim_map[i] << (i < 3 ? ", " : " }");
    out << std::endl;
    out << "active_dims = " << arg.active_dims << std::endl;
    out << "pack_blocks = " << arg.pack_blocks << std::endl;
    out << "exterior_threads = " << arg.exterior_threads << std::endl;
    out << "exterior_blocks = " << arg.exterior_blocks << std::endl;
    return out;
  }

  /**
     @brief Base class that set common types for dslash
     implementations.  Where necessary, we specialize in the derived
     classed.
   */
  struct dslash_default {
    constexpr QudaPCType pc_type() const { return QUDA_4D_PC; }
    constexpr int twist_pack() const { return 0; }
  };

  /**
     @brief This is a helper routine for spawning a CPU function for
     applying a Dslash kernel.  The dslash to be applied is passed as
     template template class (template parameter D), which is a
     functor that can apply the dslash.
   */
  template <template <typename Float, int nDim, int nColor, int nParity, bool dagger, bool xpay, KernelType kernel_type, typename Arg>
            class D,
            typename Float, int nDim, int nColor, int nParity, bool dagger, bool xpay, KernelType kernel_type, typename Arg>
  void dslashCPU(Arg arg)
  {
    D<Float, nDim, nColor, nParity, dagger, xpay, kernel_type, Arg> dslash;

    for (int parity = 0; parity < nParity; parity++) {
      // for full fields then set parity from loop else use arg setting
      parity = nParity == 2 ? parity : arg.parity;

      for (int x_cb = 0; x_cb < arg.threads; x_cb++) { // 4-d volume
        dslash(arg, x_cb, 0, parity);
      } // 4-d volumeCB
    }   // parity
  }

#ifdef NVSHMEM_COMMS
  /**
   * @brief helper function for nvshmem uber kernel to signal that the interior kernel has completed
   */
  template <KernelType kernel_type, typename Arg> void __device__ inline shmem_signalinterior(const Arg &arg)
  {
    if (kernel_type == UBER_KERNEL) {
      __syncthreads();
      if (target::thread_idx().x == 0 && target::thread_idx().y == 0 && target::thread_idx().z == 0) {
        int amlast = arg.interior_count.fetch_add(1, cuda::std::memory_order_acq_rel); // ensure that my block is done
        if (amlast == (target::grid_dim().x - arg.pack_blocks - arg.exterior_blocks) * target::grid_dim().y * target::grid_dim().z - 1) {
          arg.interior_done.store(arg.counter, cuda::std::memory_order_release);
          arg.interior_done.notify_all();
          arg.interior_count.store(0, cuda::std::memory_order_relaxed);
        }
      }
    }
  }

  template <KernelType kernel_type, int nParity, class D, typename Arg>
  void __device__ __forceinline__ shmem_exterior(D &dslash, const Arg &arg, int s)
  {
    // shmem exterior kernel with grid-strided loop
    if (kernel_type == UBER_KERNEL || kernel_type == EXTERIOR_KERNEL_ALL) {
      // figure out some details on blocks
      const bool shmem_interiordone = (arg.shmem & 64);
      const int myblockidx = arg.exterior_blocks > 0 ? target::block_idx().x - (target::grid_dim().x - arg.exterior_blocks) : target::block_idx().x;
      const int nComm = arg.commDim[0] + arg.commDim[1] + arg.commDim[2] + arg.commDim[3];
      const int blocks_per_dim = (arg.exterior_blocks > 0 ? arg.exterior_blocks : target::grid_dim().x) / (nComm);
      const int blocks_per_dir = blocks_per_dim / 2;

      int dir = (myblockidx % blocks_per_dim) / (blocks_per_dir);
      // this is the dimdir we are working on ...
      int dim;
      int threadl;
      int threads_my_dir;
      switch (myblockidx / blocks_per_dim) {
      case 0: dim = arg.dim_map[0]; break;
      case 1: dim = arg.dim_map[1]; break;
      case 2: dim = arg.dim_map[2]; break;
      case 3: dim = arg.dim_map[3]; break;
      default: dim = -1;
      }

      switch (dim) {
      case 0:
        threads_my_dir = (arg.threadDimMapUpper[0] - arg.threadDimMapLower[0]) / 2;
        threadl = arg.threadDimMapLower[0];
        break;
      case 1:
        threads_my_dir = (arg.threadDimMapUpper[1] - arg.threadDimMapLower[1]) / 2;
        threadl = arg.threadDimMapLower[1];
        break;
      case 2:
        threads_my_dir = (arg.threadDimMapUpper[2] - arg.threadDimMapLower[2]) / 2;
        threadl = arg.threadDimMapLower[2];
        break;
      case 3:
        threads_my_dir = (arg.threadDimMapUpper[3] - arg.threadDimMapLower[3]) / 2;
        threadl = arg.threadDimMapLower[3];
        break;
      default: threadl = 0; threads_my_dir = 0;
      }
      int dimdir = 2 * dim + dir;
      constexpr bool shmembarrier = true; // always true for now (arg.shmem & 16);

      if (shmembarrier) {

        if (shmem_interiordone && target::thread_idx().x == target::block_dim().x - 1 && target::thread_idx().y == 0 && target::thread_idx().z == 0) {
          auto tst_val = arg.interior_done.load(cuda::std::memory_order_relaxed);
          while (tst_val < arg.counter - 1) {
            arg.interior_done.compare_exchange_strong(tst_val, arg.counter - 1, cuda::std::memory_order_relaxed,
                                                      cuda::std::memory_order_relaxed);
          }
          arg.interior_done.wait(arg.counter - 1, cuda::std::memory_order_acquire);
        }

        if (target::thread_idx().x < 8 && target::thread_idx().y == 0 && target::thread_idx().z == 0) {
          /* the first 8 threads of each block are used for spinning on halo data coming
            in from the 4*2 (dim*dir) neighbors. We figure out next on which neighbors the
            block actually needs to wait
          */

          // for now we can only spin per dimdir for 4d indexing as it ensure unique block->dimdir assignment
          bool spin = (dslash.pc_type() == QUDA_5D_PC) || (target::thread_idx().x == dimdir);
          // figure out which other directions also to spin for (to make corners work)
          switch (dim) {
          case 3:
            if (arg.commDim[3]) {
              spin = target::thread_idx().x / 2 < 3 ? arg.commDim[2] : spin;
              spin = target::thread_idx().x / 2 < 2 ? arg.commDim[1] : spin;
              spin = target::thread_idx().x / 2 < 1 ? arg.commDim[0] : spin;
            } else {
              spin = false;
            }
            break;
          case 2:
            if (arg.commDim[2]) {
              if (arg.commDim[1]) spin = target::thread_idx().x / 2 < 2 ? true : spin;
              if (arg.commDim[0]) spin = target::thread_idx().x / 2 < 1 ? true : spin;
            }
            break;
          case 1:
            if (arg.commDim[1]) {
              if (arg.commDim[0]) spin = target::thread_idx().x / 2 < 1 ? true : spin;
            }
            break;
          case 0: break;
          }

          if (getNeighborRank(target::thread_idx().x, arg) >= 0) {
            if (spin) { nvshmem_signal_wait_until((arg.sync_arr + target::thread_idx().x), NVSHMEM_CMP_GE, arg.counter); }
          }
        }

        // wait for all threads here as not all threads spin
        __syncthreads();
        // do exterior
      }

      int local_tid = target::thread_idx().x + target::block_dim().x * (myblockidx % (blocks_per_dir)); // index within the block
      int tid = local_tid + threadl + dir * threads_my_dir; // global index corresponding to local_tid

      while (local_tid < threads_my_dir) {
        // for full fields set parity from z thread index else use arg setting
        int parity = nParity == 2 ? target::block_dim().z * target::block_idx().z + target::thread_idx().z : arg.parity;
#ifdef QUDA_DSLASH_FAST_COMPILE
        dslash.template operator()<EXTERIOR_KERNEL_ALL>(tid, s, parity);
#else
        switch (parity) {
        case 0: dslash.template operator()<EXTERIOR_KERNEL_ALL>(tid, s, 0); break;
        case 1: dslash.template operator()<EXTERIOR_KERNEL_ALL>(tid, s, 1); break;
        }
#endif
        local_tid += target::block_dim().x * blocks_per_dir;
        tid += target::block_dim().x * blocks_per_dir;
      }
    }
  }

#endif // NVSHMEM_COMMS

  /**
    @brief This is the wrapper arg struct for driving the dslash_functor.  The dslash to
    be applied is passed as a template template class (template
    parameter D), which is a functor that can apply the dslash.  The
    packing routine (P) to be used is similarly passed.
   */
  template <template <int nParity, bool dagger, bool xpay, KernelType kernel_type, typename Arg> class D_,
            template <bool dagger, QudaPCType pc, typename Arg> class P_, int nParity_, bool dagger_, bool xpay_,
            KernelType kernel_type_, typename Arg_>
  struct dslash_functor_arg : kernel_param<use_kernel_arg> {
    using Arg = Arg_;
    using D = D_<nParity_, dagger_, xpay_, kernel_type_, Arg>;
    template <QudaPCType pc> using P = P_<dagger_, pc, Arg>;
    static constexpr int nParity = nParity_;
    static constexpr bool dagger = dagger_;
    static constexpr bool xpay = xpay_;
    static constexpr KernelType kernel_type = kernel_type_;
    Arg arg;

    dslash_functor_arg(const Arg &arg, unsigned int threads_x) :
      kernel_param(dim3(threads_x, arg.dc.Ls, arg.nParity)),
      arg(arg) { }
  };

  /**
    @brief This is the functor for the dslash stencils.

    When running an interior kernel, the first few "pack_blocks" CTAs
    are reserved for data packing, which may include communication to
    neighboring processes.
   */
  template <typename Arg> struct dslash_functor {
    const typename Arg::Arg &arg;
    static constexpr int nParity = Arg::nParity;
    static constexpr bool dagger = Arg::dagger;
    static constexpr KernelType kernel_type = Arg::kernel_type;
    static constexpr const char *filename() { return Arg::D::filename(); }
    constexpr dslash_functor(const Arg &arg) : arg(arg.arg) { }

    __forceinline__ __device__ void operator()(int, int s, int parity)
    {
      typename Arg::D dslash(arg);
      // for full fields set parity from z thread index else use arg setting
      if (nParity == 1) parity = arg.parity;

      if ((kernel_type == INTERIOR_KERNEL || kernel_type == UBER_KERNEL) &&
          target::block_idx().x < static_cast<unsigned int>(arg.pack_blocks)) {
        // first few blocks do packing kernel
        typename Arg::template P<dslash.pc_type()> packer;
        packer(arg, s, 1 - parity, dslash.twist_pack()); // flip parity since pack is on input

        // we use that when running the exterior -- this is either
        // * an explicit call to the exterior when not merged with the interior or
        // * the interior with exterior_blocks > 0
#ifdef NVSHMEM_COMMS
      } else if (arg.shmem > 0
                 && ((kernel_type == EXTERIOR_KERNEL_ALL && arg.exterior_blocks == 0)
                     || (kernel_type == UBER_KERNEL && arg.exterior_blocks > 0
                         && target::block_idx().x >= (target::grid_dim().x - arg.exterior_blocks)))) {
        shmem_exterior<kernel_type, nParity>(dslash, arg, s);
#endif
      } else {
        const int dslash_block_offset
          = ((kernel_type == INTERIOR_KERNEL || kernel_type == UBER_KERNEL) ? arg.pack_blocks : 0);
        int x_cb = (target::block_idx().x - dslash_block_offset) * target::block_dim().x + target::thread_idx().x;
        if (x_cb >= arg.threads) return;

#ifdef QUDA_DSLASH_FAST_COMPILE
        dslash.template operator()<kernel_type == UBER_KERNEL ? INTERIOR_KERNEL : kernel_type>(x_cb, s, parity);
#else
        switch (parity) {
        case 0: dslash.template operator()<kernel_type == UBER_KERNEL ? INTERIOR_KERNEL : kernel_type>(x_cb, s, 0); break;
        case 1: dslash.template operator()<kernel_type == UBER_KERNEL ? INTERIOR_KERNEL : kernel_type>(x_cb, s, 1); break;
        }
#endif
#ifdef NVSHMEM_COMMS
        if (kernel_type == UBER_KERNEL) shmem_signalinterior<kernel_type>(arg);
#endif
      }
    }
  };

} // namespace quda
