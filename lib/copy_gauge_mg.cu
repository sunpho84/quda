#include <gauge_field_order.h>

#define FINE_GRAINED_ACCESS

#include <copy_gauge_helper.cuh>

namespace quda {
  
  template <typename sFloatOut, typename FloatIn, int Nc, typename InOrder>
  void copyGaugeMG(const InOrder &inOrder, GaugeField &out, const GaugeField &in,
		   QudaFieldLocation location, sFloatOut *Out, sFloatOut **outGhost, int type)
  {
    typedef typename mapper<sFloatOut>::type FloatOut;
    constexpr int length = 2*Nc*Nc;

    if (out.Reconstruct() != QUDA_RECONSTRUCT_NO)
      errorQuda("Reconstruct type %d not supported", out.Reconstruct());

#ifdef FINE_GRAINED_ACCESS
    if (out.Precision() == QUDA_HALF_PRECISION) {
      if (in.Precision() == QUDA_HALF_PRECISION) {
	out.Scale(in.Scale());
      } else {
	InOrder in_(const_cast<GaugeField&>(in));
	out.Scale( in.abs_max() );
      }
    }
#endif

    if (out.isNative()) {

#ifdef FINE_GRAINED_ACCESS
      if (outGhost) {
	typedef typename gauge::FieldOrder<FloatOut,Nc,1,QUDA_FLOAT2_GAUGE_ORDER,false,sFloatOut> G;
	copyGauge<FloatOut,FloatIn,length>(G(out, Out, outGhost), inOrder, out, in, location, type);
      } else {
	typedef typename gauge::FieldOrder<FloatOut,Nc,1,QUDA_FLOAT2_GAUGE_ORDER,true,sFloatOut> G;
	copyGauge<FloatOut,FloatIn,length>(G(out, Out, outGhost), inOrder, out, in, location, type);
      }
#else
      typedef typename gauge_mapper<FloatOut,QUDA_RECONSTRUCT_NO,length>::type G;
      copyGauge<FloatOut,FloatIn,length>
	(G(out,Out,outGhost), inOrder, out, in, location, type);
#endif

    } else if (out.Order() == QUDA_QDP_GAUGE_ORDER) {

#ifdef FINE_GRAINED_ACCESS
      typedef typename gauge::FieldOrder<FloatOut,Nc,1,QUDA_QDP_GAUGE_ORDER,true,sFloatOut> G;
      copyGauge<FloatOut,FloatIn,length>(G(out, Out, outGhost), inOrder, out, in, location, type);
#else
      typedef typename QDPOrder<FloatOut,length> G;
      copyGauge<FloatOut,FloatIn,length>(G(out, Out, outGhost), inOrder, out, in, location, type);
#endif

    } else if (out.Order() == QUDA_MILC_GAUGE_ORDER) {

#ifdef FINE_GRAINED_ACCESS
      typedef typename gauge::FieldOrder<FloatOut,Nc,1,QUDA_MILC_GAUGE_ORDER,true,sFloatOut> G;
      copyGauge<FloatOut,FloatIn,length>(G(out, Out, outGhost), inOrder, out, in, location, type);
#else
      typedef typename MILCOrder<FloatOut,length> G;
      copyGauge<FloatOut,FloatIn,length>(G(out, Out, outGhost), inOrder, out, in, location, type);
#endif

    } else {
      errorQuda("Gauge field %d order not supported", out.Order());
    }

  }

  template <typename sFloatOut, typename sFloatIn, int Nc>
    void copyGaugeMG(GaugeField &out, const GaugeField &in, QudaFieldLocation location,
		     sFloatOut *Out, sFloatIn *In, sFloatOut **outGhost, sFloatIn **inGhost, int type)
  {
    typedef typename mapper<sFloatIn>::type FloatIn;
#ifndef FINE_GRAINED_ACCESS
    constexpr int length = 2*Nc*Nc;
#endif

    if (in.Reconstruct() != QUDA_RECONSTRUCT_NO) 
      errorQuda("Reconstruct type %d not supported", in.Reconstruct());

    if (in.isNative()) {      
#ifdef FINE_GRAINED_ACCESS
      if (inGhost) {
	typedef typename gauge::FieldOrder<FloatIn,Nc,1,QUDA_FLOAT2_GAUGE_ORDER,false,sFloatIn> G;
	copyGaugeMG<sFloatOut,FloatIn,Nc> (G(const_cast<GaugeField&>(in),In,inGhost), out, in, location, Out, outGhost, type);
      } else {
	typedef typename gauge::FieldOrder<FloatIn,Nc,1,QUDA_FLOAT2_GAUGE_ORDER,true,sFloatIn> G;
	copyGaugeMG<sFloatOut,FloatIn,Nc> (G(const_cast<GaugeField&>(in),In,inGhost), out, in, location, Out, outGhost, type);
      }
#else
      typedef typename gauge_mapper<FloatIn,QUDA_RECONSTRUCT_NO,length>::type G;
      copyGaugeMG<sFloatOut,FloatIn,Nc> (G(in, In,inGhost), out, in, location, Out, outGhost, type);
#endif
    } else if (in.Order() == QUDA_QDP_GAUGE_ORDER) {

#ifdef FINE_GRAINED_ACCESS
      typedef typename gauge::FieldOrder<FloatIn,Nc,1,QUDA_QDP_GAUGE_ORDER,true,sFloatIn> G;
      copyGaugeMG<sFloatOut,FloatIn,Nc>(G(const_cast<GaugeField&>(in),In,inGhost), out, in, location, Out, outGhost, type);
#else
      typedef typename QDPOrder<FloatIn,length> G;
      copyGaugeMG<sFloatOut,FloatIn,Nc>(G(in, In, inGhost), out, in, location, Out, outGhost, type);
#endif

    } else if (in.Order() == QUDA_MILC_GAUGE_ORDER) {

#ifdef FINE_GRAINED_ACCESS
      typedef typename gauge::FieldOrder<FloatIn,Nc,1,QUDA_MILC_GAUGE_ORDER,true,sFloatIn> G;
      copyGaugeMG<sFloatOut,FloatIn,Nc>(G(const_cast<GaugeField&>(in),In,inGhost), out, in, location, Out, outGhost, type);
#else
      typedef typename MILCOrder<FloatIn,length> G;
      copyGaugeMG<sFloatOut,FloatIn,Nc>(G(in, In, inGhost), out, in, location, Out, outGhost, type);
#endif

    } else {
      errorQuda("Gauge field %d order not supported", in.Order());
    }
  }

#ifdef GPU_MULTIGRID
  template <typename FloatOut, typename FloatIn>
  void copyGaugeMG(GaugeField &out, const GaugeField &in, QudaFieldLocation location, FloatOut *Out, 
		   FloatIn *In, FloatOut **outGhost, FloatIn **inGhost, int type)
  {
    switch (in.Ncolor()) {
    case 48: copyGaugeMG<FloatOut,FloatIn,48>(out, in, location, Out, In, outGhost, inGhost, type); break;
#ifdef NSPIN4
    case 12: copyGaugeMG<FloatOut,FloatIn,12>(out, in, location, Out, In, outGhost, inGhost, type); break;
    case 64: copyGaugeMG<FloatOut,FloatIn,64>(out, in, location, Out, In, outGhost, inGhost, type); break;
#endif
#ifdef NSPIN1
    case 128: copyGaugeMG<FloatOut,FloatIn,128>(out, in, location, Out, In, outGhost, inGhost, type); break;
    case 192: copyGaugeMG<FloatOut,FloatIn,192>(out, in, location, Out, In, outGhost, inGhost, type); break;
#endif
    default: errorQuda("Unsupported number of colors; out.Nc=%d, in.Nc=%d", out.Ncolor(), in.Ncolor());
    }
  }
#else
  template <typename FloatOut, typename FloatIn>
  void copyGaugeMG(GaugeField &, const GaugeField &, QudaFieldLocation, FloatOut *, FloatIn *, FloatOut **, FloatIn **, int)
  {
    errorQuda("Multigrid has not been enabled");
  }
#endif // GPU_MULTIGRID

  // this is the function that is actually called, from here on down we instantiate all required templates
  void copyGenericGaugeMG(GaugeField &out, const GaugeField &in, QudaFieldLocation location,
			  void *Out, void *In, void **ghostOut, void **ghostIn, int type)
  {
#ifndef FINE_GRAINED_ACCESS
    if (out.Precision() == QUDA_HALF_PRECISION || in.Precision() == QUDA_HALF_PRECISION)
      errorQuda("Precision format not supported");
#endif

    if (out.Precision() == QUDA_DOUBLE_PRECISION) {
#ifdef GPU_MULTIGRID_DOUBLE
      if (in.Precision() == QUDA_DOUBLE_PRECISION) {
	copyGaugeMG(out, in, location, (double*)Out, (double*)In, (double**)ghostOut, (double**)ghostIn, type);
      } else if (in.Precision() == QUDA_SINGLE_PRECISION) {
	copyGaugeMG(out, in, location, (double*)Out, (float*)In, (double**)ghostOut, (float**)ghostIn, type);
      } else if (in.Precision() == QUDA_HALF_PRECISION) {
	copyGaugeMG(out, in, location, (double*)Out, (short*)In, (double**)ghostOut, (short**)ghostIn, type);
      } else {
	errorQuda("Precision %d not supported", in.Precision());
      }
#else
      errorQuda("Double precision multigrid has not been enabled");
#endif
    } else if (out.Precision() == QUDA_SINGLE_PRECISION) {
      if (in.Precision() == QUDA_DOUBLE_PRECISION) {
#ifdef GPU_MULTIGRID_DOUBLE
	copyGaugeMG(out, in, location, (float*)Out, (double*)In, (float**)ghostOut, (double**)ghostIn, type);
#else
	errorQuda("Double precision multigrid has not been enabled");
#endif
      } else if (in.Precision() == QUDA_SINGLE_PRECISION) {
	copyGaugeMG(out, in, location, (float*)Out, (float*)In, (float**)ghostOut, (float**)ghostIn, type);
      } else if (in.Precision() == QUDA_HALF_PRECISION) {
	copyGaugeMG(out, in, location, (float*)Out, (short*)In, (float**)ghostOut, (short**)ghostIn, type);
      } else {
	errorQuda("Precision %d not supported", in.Precision());
      }
    } else if (out.Precision() == QUDA_HALF_PRECISION) {
      if (in.Precision() == QUDA_DOUBLE_PRECISION) {
#ifdef GPU_MULTIGRID_DOUBLE
	copyGaugeMG(out, in, location, (short*)Out, (double*)In, (short**)ghostOut, (double**)ghostIn, type);
#else
	errorQuda("Double precision multigrid has not been enabled");
#endif
      } else if (in.Precision() == QUDA_SINGLE_PRECISION) {
	copyGaugeMG(out, in, location, (short*)Out, (float*)In, (short**)ghostOut, (float**)ghostIn, type);
      } else if (in.Precision() == QUDA_HALF_PRECISION) {
	copyGaugeMG(out, in, location, (short*)Out, (short*)In, (short**)ghostOut, (short**)ghostIn, type);
      } else {
	errorQuda("Precision %d not supported", in.Precision());
      }
    } else {
      errorQuda("Precision %d not supported", out.Precision());
    } 
  } 

} // namespace quda
