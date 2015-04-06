/*******************************************************
 * Copyright (c) 2014, ArrayFire
 * All rights reserved.
 *
 * This file is distributed under 3-clause BSD license.
 * The complete license agreement can be obtained at:
 * http://arrayfire.com/licenses/BSD-3-Clause
 ********************************************************/

#include <qr.hpp>
#include <err_common.hpp>

#if defined(WITH_LINEAR_ALGEBRA)

#include <cusolverDnManager.hpp>
#include <cublas_v2.h>
#include <identity.hpp>
#include <memory.hpp>
#include <copy.hpp>

#include <math.hpp>
#include <err_common.hpp>

#include <kernel/qr_split.hpp>

namespace cuda
{

//cusolverStatus_t cusolverDn<>geqrf_bufferSize(
//        cusolverDnHandle_t handle,
//        int m, int n,
//        <> *A,
//        int lda,
//        int *Lwork );
//
//cusolverStatus_t cusolverDn<>geqrf(
//        cusolverDnHandle_t handle,
//        int m, int n,
//        <> *A, int lda,
//        <> *TAU,
//        <> *Workspace,
//        int Lwork, int *devInfo );
//
//cusolverStatus_t cusolverDn<>mqr(
//        cusolverDnHandle_t handle,
//        cublasSideMode_t side, cublasOperation_t trans,
//        int m, int n, int k,
//        const double *A, int lda,
//        const double *tau,
//        double *C, int ldc,
//        double *work,
//        int lwork, int *devInfo);

template<typename T>
struct geqrf_func_def_t
{
    typedef cusolverStatus_t (*geqrf_func_def) (
                              cusolverDnHandle_t, int, int,
                              T *, int,
                              T *,
                              T *,
                              int, int *);
};

template<typename T>
struct geqrf_buf_func_def_t
{
    typedef cusolverStatus_t (*geqrf_buf_func_def) (
                              cusolverDnHandle_t, int, int,
                              T *, int, int *);
};

template<typename T>
struct mqr_func_def_t
{
    typedef cusolverStatus_t (*mqr_func_def) (
                              cusolverDnHandle_t,
                              cublasSideMode_t, cublasOperation_t,
                              int, int, int,
                              const T *, int,
                              const T *,
                              T *, int,
                              T *, int,
                              int *);
};

#define QR_FUNC_DEF( FUNC )                                                     \
template<typename T>                                                            \
typename FUNC##_func_def_t<T>::FUNC##_func_def                                  \
FUNC##_func();                                                                  \
                                                                                \
template<typename T>                                                            \
typename FUNC##_buf_func_def_t<T>::FUNC##_buf_func_def                          \
FUNC##_buf_func();                                                              \

#define QR_FUNC( FUNC, TYPE, PREFIX )                                                           \
template<> typename FUNC##_func_def_t<TYPE>::FUNC##_func_def FUNC##_func<TYPE>()                \
{ return &cusolverDn##PREFIX##FUNC; }                                                           \
                                                                                                \
template<> typename FUNC##_buf_func_def_t<TYPE>::FUNC##_buf_func_def FUNC##_buf_func<TYPE>()    \
{ return & cusolverDn##PREFIX##FUNC##_bufferSize; }

QR_FUNC_DEF( geqrf )
QR_FUNC(geqrf , float  , S)
QR_FUNC(geqrf , double , D)
QR_FUNC(geqrf , cfloat , C)
QR_FUNC(geqrf , cdouble, Z)

#define MQR_FUNC_DEF( FUNC )                                                    \
template<typename T>                                                            \
typename FUNC##_func_def_t<T>::FUNC##_func_def                                  \
FUNC##_func();

#define MQR_FUNC( FUNC, TYPE, PREFIX )                                                          \
template<> typename FUNC##_func_def_t<TYPE>::FUNC##_func_def FUNC##_func<TYPE>()                \
{ return &cusolverDn##PREFIX; }                                                                 \

MQR_FUNC_DEF( mqr )
MQR_FUNC(mqr , float  , Sormqr)
MQR_FUNC(mqr , double , Dormqr)
MQR_FUNC(mqr , cfloat , Cunmqr)
MQR_FUNC(mqr , cdouble, Zunmqr)

template<typename T>
void qr(Array<T> &q, Array<T> &r, Array<T> &t, const Array<T> &in)
{
    dim4 iDims = in.dims();
    int M = iDims[0];
    int N = iDims[1];

    Array<T> in_copy = copyArray<T>(in);

    int lwork = 0;

    cusolverStatus_t err;
    err = geqrf_buf_func<T>()(getSolverHandle(), M, N,
                              in_copy.get(), M, &lwork);

    if(err != CUSOLVER_STATUS_SUCCESS) {
        std::cout <<__PRETTY_FUNCTION__<< " ERROR: " << cusolverErrorString(err) << std::endl;
    }

    T *workspace = memAlloc<T>(lwork);

    t = createEmptyArray<T>(af::dim4(min(M, N), 1, 1, 1));
    int *info = memAlloc<int>(1);
    err = geqrf_func<T>()(getSolverHandle(), M, N,
                          in_copy.get(), M,
                          t.get(),
                          workspace,
                          lwork, info);

    if(err != CUSOLVER_STATUS_SUCCESS) {
        std::cout <<__PRETTY_FUNCTION__<< " ERROR: " << cusolverErrorString(err) << std::endl;
    }

    // SPLIT into q and r
    dim4 rdims(M, N);
    r = createEmptyArray<T>(rdims);

    kernel::qr_split<T>(r, in_copy);

    dim4 qdims(M, N);

    q = identity<T>(qdims);

    err = mqr_func<T>()(getSolverHandle(),
                        CUBLAS_SIDE_LEFT, CUBLAS_OP_N,
                        M, N, min(M, N),
                        in_copy.get(), M,
                        t.get(),
                        q.get(), q.dims()[0],
                        workspace, lwork,
                        info);

    q.resetDims(dim4(M, M));

    if(err != CUSOLVER_STATUS_SUCCESS) {
        std::cout <<__PRETTY_FUNCTION__<< " ERROR: " << cusolverErrorString(err) << std::endl;
    }
}

template<typename T>
Array<T> qr_inplace(Array<T> &in)
{
    dim4 iDims = in.dims();
    int M = iDims[0];
    int N = iDims[1];

    Array<T> t = createEmptyArray<T>(af::dim4(min(M, N), 1, 1, 1));

    int lwork = 0;

    cusolverStatus_t err;
    err = geqrf_buf_func<T>()(getSolverHandle(), M, N,
                              in.get(), M, &lwork);

    if(err != CUSOLVER_STATUS_SUCCESS) {
        std::cout <<__PRETTY_FUNCTION__<< " ERROR: " << cusolverErrorString(err) << std::endl;
    }

    T *workspace = memAlloc<T>(lwork);
    int *info = memAlloc<int>(1);

    err = geqrf_func<T>()(getSolverHandle(), M, N,
                          in.get(), M,
                          t.get(), workspace,
                          lwork, info);

    if(err != CUSOLVER_STATUS_SUCCESS) {
        std::cout <<__PRETTY_FUNCTION__<< " ERROR: " << cusolverErrorString(err) << std::endl;
    }

    return t;
}

#define INSTANTIATE_QR(T)                                                                           \
    template Array<T> qr_inplace<T>(Array<T> &in);                                                \
    template void qr<T>(Array<T> &q, Array<T> &r, Array<T> &t, const Array<T> &in);

INSTANTIATE_QR(float)
INSTANTIATE_QR(cfloat)
INSTANTIATE_QR(double)
INSTANTIATE_QR(cdouble)
}

#else
namespace cuda
{

template<typename T>
void qr(Array<T> &q, Array<T> &r, Array<T> &t, const Array<T> &in)
{
    AF_ERROR("CUDA cusolver not available. Linear Algebra is disabled",
             AF_ERR_NOT_CONFIGURED);
}

template<typename T>
Array<T> qr_inplace(Array<T> &in)
{
    AF_ERROR("CUDA cusolver not available. Linear Algebra is disabled",
             AF_ERR_NOT_CONFIGURED);
}

#define INSTANTIATE_QR(T)                                                                           \
    template Array<T> qr_inplace<T>(Array<T> &in);                                                \
    template void qr<T>(Array<T> &q, Array<T> &r, Array<T> &t, const Array<T> &in);

INSTANTIATE_QR(float)
INSTANTIATE_QR(cfloat)
INSTANTIATE_QR(double)
INSTANTIATE_QR(cdouble)

}

#endif
