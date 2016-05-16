module ToeplitzMatrices

using Debug

import StatsBase
include("iterativeLinearSolvers.jl")

import Base: *, \, full, getindex, print_matrix, size, tril, triu, inv, A_mul_B!, Ac_mul_B,
    A_ldiv_B!, convert
import Base.LinAlg: BlasReal, DimensionMismatch


export Toeplitz, SymmetricToeplitz, Circulant, TriangularToeplitz, Hankel,
       chan, strang

# Abstract
abstract AbstractToeplitz{T<:Number} <: AbstractMatrix{T}

size(A::AbstractToeplitz) = (size(A, 1), size(A, 2))
getindex(A::AbstractToeplitz, i::Integer) = A[mod(i, size(A,1)), div(i, size(A,1)) + 1]

# Convert an abstract Toeplitz matrix to a full matrix
function full{T}(A::AbstractToeplitz{T})
    m, n = size(A)
    Af = Array(T, m, n)
    for j = 1:n
        for i = 1:m
            Af[i,j] = A[i,j]
        end
    end
    return Af
end

# Fast application of a general Toeplitz matrix to a column vector via FFT
function A_mul_B!{T}(α::T, A::AbstractToeplitz{T}, x::StridedVector{T}, β::T,
        y::StridedVector{T})
    m = size(A,1)
    n = size(A,2)
    N = length(A.vcvr_dft)
    if m != length(y)
        throw(DimensionMismatch(""))
    end
    if n != length(x)
        throw(DimensionMismatch(""))
    end
    if N < 512
        y[:] *= β
        for j = 1:n
            tmp = α * x[j]
            for i = 1:m
                y[i] += tmp*A[i,j]
            end
        end
        return y
    end
    for i = 1:n
        A.tmp[i] = complex(x[i])
    end
    for i = n+1:N
        A.tmp[i] = zero(Complex{T})
    end
    A_mul_B!(A.tmp, A.dft, A.tmp)
    for i = 1:N
        A.tmp[i] *= A.vcvr_dft[i]
    end
    A.dft \ A.tmp
    for i = 1:m
        y[i] *= β
        y[i] += α * real(A.tmp[i])
    end
    return y
end

# Application of a general Toeplitz matrix to a general matrix
function A_mul_B!{T}(α::T, A::AbstractToeplitz{T}, B::StridedMatrix{T}, β::T,
    C::StridedMatrix{T})
    l = size(B, 2)
    if size(C, 2) != l
        throw(DimensionMismatch("input and output matrices must have same number of columns"))
    end
    for j = 1:l
        A_mul_B!(α, A, sub(B, :, j), β, sub(C, :, j))
    end
    return C
end

# * operator
(*){T}(A::AbstractToeplitz{T}, B::StridedVecOrMat{T}) =
    A_mul_B!(one(T), A, B, zero(T), size(B,2) == 1 ? zeros(T, size(A, 1)) : zeros(T, size(A, 1), size(B, 2)))

# Left division of a general matrix B by a general Toeplitz matrix A, i.e. the solution x of Ax=B.
function A_ldiv_B!(A::AbstractToeplitz, B::StridedMatrix)
  if size(A, 1) != size(A, 2)
    error("Division: Rectangular case is not supported.")
  end
  for j = 1:size(B, 2)
      A_ldiv_B!(A, sub(B, :, j))
  end
  return B
end

# General Toeplitz matrix
type Toeplitz{T<:Number} <: AbstractToeplitz{T}
    vc::Vector{T}
    vr::Vector{T}
    vcvr_dft::Vector{Complex{T}}
    tmp::Vector{Complex{T}}
    dft::Base.DFT.Plan{Complex{T}}
end

# Ctor
function Toeplitz{T<:Number}(vc::Vector{T}, vr::Vector{T})
    m = length(vc)
    if vc[1] != vr[1]
        error("First element of the vectors must be the same")
    end

    tmp = complex([vc; reverse(vr[2:end])])
    dft = plan_fft!(tmp)
    return Toeplitz(vc, vr, dft*tmp, similar(tmp), dft)
end

# Conversion to Float for integer inputs
Toeplitz{T<:Integer}(vc::Vector{T}, vr::Vector{T}) =
            Toeplitz(Vector{Float64}(vc),Vector{Float64}(vr))
Toeplitz{T<:Integer}(vc::Vector{Complex{T}}, vr::Vector{Complex{T}}) =
            Toeplitz(Vector{Complex128}(vc),Vector{Complex128}(vr))

# Input promotion
function Toeplitz{T1<:Number,T2<:Number}(vc::Vector{T1},vr::Vector{T2})
    T=promote_type(T1,T2)
    Toeplitz(Vector{T}(vc),Vector{T}(vr))
end

# Size of a general Toeplitz matrix
function size(A::Toeplitz, dim::Int)
    if dim == 1
        return length(A.vc)
    elseif dim == 2
        return length(A.vr)
    elseif dim > 2
        return 1
    else
        error("arraysize: dimension out of range")
    end
end

# Fetch an entry
function getindex(A::Toeplitz, i::Integer, j::Integer)
    m = size(A,1)
    n = size(A,2)
    if i > m || j > n
        error("BoundsError()")
    end

    if i >= j
        return A.vc[i - j + 1]
    else
        return A.vr[1 - i + j]
    end
end

# Form a lower triangular Toeplitz matrix by annihilating all entries above the k-th diaganal
function tril{T}(A::Toeplitz{T}, k = 0)
    if k > 0
        error("Second argument cannot be positive")
    end
    Al = TriangularToeplitz(copy(A.vc), 'L', length(A.vr))
    if k < 0
      for i in -1:-1:k
          Al.ve[-i] = zero(T)
      end
    end
    return Al
end

# Form a lower triangular Toeplitz matrix by annihilating all entries below the k-th diaganal
function triu{T}(A::Toeplitz{T}, k = 0)
    if k < 0
        error("Second argument cannot be negative")
    end
    Al = TriangularToeplitz(copy(A.vr), 'U', length(A.vc))
    if k > 0
      for i in 1:k
          Al.ve[i] = zero(T)
      end
    end
    return Al
end

# Left division of a column vector b by a general Toeplitz matrix A, i.e. the solution x of Ax=b.
A_ldiv_B!(A::Toeplitz, b::StridedVector) =
    copy!(b, IterativeLinearSolvers.cgs(A, zeros(length(b)), b, strang(A), 1000, 100eps())[1])

# Symmetric Toeplitz matrix
type SymmetricToeplitz{T<:BlasReal} <: AbstractToeplitz{T}
    ve::Vector{T}
    cr:: Char   # Is the vector ve the first column or the top row?
    k:: Integer # The other dimension
    vcvr_dft::Vector{Complex{T}}
    tmp::Vector{Complex{T}}
    dft::Base.DFT.Plan
end

# Ctor
function SymmetricToeplitz{T<:BlasReal}(ve::Vector{T}, cr = 'c', k = length(ve))
    @assert length(ve) >= k
    if cr == 'c'
      tmp = convert(Array{Complex{T}}, [ve; reverse(ve[2:k])])
    elseif cr == 'r'
      tmp = convert(Array{Complex{T}}, [ve[1:k]; reverse(ve[2:end])])
    else
      error("SymmetricTeoplitz: the input character cr can only be either c or r.")
    end
    dft = plan_fft!(tmp)
    return SymmetricToeplitz(ve, cr, k, dft*tmp, similar(tmp), dft)
end

# Size
function size(A::SymmetricToeplitz, dim::Int)
    if dim == 1
      if A.cr == 'c'
        return length(A.ve)
      else
        return A.k
      end
    elseif dim == 2
      if A.cr == 'c'
          return A.k
      else
        return length(A.ve)
      end
    else
        error("arraysize: dimension out of range")
    end
end

# Fetch an entry
function getindex(A::SymmetricToeplitz, i::Integer, j::Integer)
   @assert ( 1 <= i <= size(A,1) && 1 <= j <= size(A,2) )
   A.ve[abs(i - j) + 1]
end

# Left division of a column vector b by a symmetric Toeplitz matrix A, i.e. the solution x of Ax=b.
A_ldiv_B!(A::SymmetricToeplitz, b::StridedVector) =
    copy!(b, IterativeLinearSolvers.cg(A, zeros(length(b)), b, strang(A), 1000, 100eps())[1])

# Circulant
type Circulant{T<:BlasReal} <: AbstractToeplitz{T}
    ve::Vector{T}
    cr::Char
    k::Integer
    vcvr_dft::Vector{Complex{T}}
    tmp::Vector{Complex{T}}
    dft::Base.DFT.Plan
end

# Ctor
function Circulant{T<:BlasReal}(ve::Vector{T}, cr = 'c', k = length(ve))
    tmp = zeros(Complex{T}, length(ve))
    dft = plan_fft!(tmp)
    if cr == 'c'
      p = ve
    elseif cr == 'r'
      p = [ve[1]; ve[end:-1:2]]
    else
      error("Unrecognizable input for cr.")
    end
    return Circulant(ve, cr, k, dft*p, tmp, dft)
end

# Size
function size(A::Circulant, dim::Integer)
  if dim == 1
    if A.cr == 'c'
      return length(A.ve)
    else
      return A.k
    end
  elseif dim == 2
    if A.cr == 'c'
        return A.k
    else
      return length(A.ve)
    end
  else
      error("arraysize: dimension out of range")
  end
end

# Retrieve an entry
function getindex(A::Circulant, i::Integer, j::Integer)
  m = size(A, 1)
  n = size(A, 2)
  if i > m || j > n
      error("BoundsError()")
  end
  if A.cr == 'c'
    p = A.ve
  elseif A.cr == 'r'
    p = [A.ve[1]; A.ve[end:-1:2]]
  end
  return p[mod(i - j, max(m, n)) + 1]
end

# Fast multiplication of the conjugate of a circulant matrix with another circulant matrix
function Ac_mul_B(A::Circulant,B::Circulant)
  if size(A, 1) != size(A, 2) || size(B, 1) != size(B, 2)
    error("Multiplication: Rectangular case is not supported.")
  end
  tmp = similar(A.vc_dft)
  for i = 1:length(tmp)
      tmp[i] = conj(A.vc_dft[i]) * B.vc_dft[i]
  end
  return Circulant(real(A.dft \ tmp), tmp, A.tmp, A.dft)
end

# Left division of a column vector b by a circulant matrix A, i.e. the solution x of Ax=b.
function A_ldiv_B!{T}(A::Circulant{T}, b::AbstractVector{T})
    if size(A, 1) != size(A, 2)
      error("Division: Rectangular case is not supported.")
    end
    n = length(b)
    size(A, 1) == n || throw(DimensionMismatch(""))
    for i = 1:n
        A.tmp[i] = b[i]
    end
    A.dft * A.tmp
    for i = 1:n
        A.tmp[i] /= A.vcvr_dft[i]
    end
    A.dft \ A.tmp
    for i = 1:n
        b[i] = real(A.tmp[i])
    end
    return b
end

# Operator \
(\)(A::Circulant, b::AbstractVector) = A_ldiv_B!(A, copy(b))

# Inverse of a square circulant matrix
function inv{T<:BlasReal}(A::Circulant{T})
    if size(A, 1) != size(A, 2)
      error("Inverse: Rectangular case is not supported.")
    end
    vdft = 1 ./ A.vcvr_dft
    return Circulant(real(A.dft \ vdft), copy(vdft), similar(vdft), A.dft)
end

# Strang matrix
function strang{T}(A::AbstractMatrix{T})
    n = size(A, 1)
    v = Array(T, n)
    n2 = div(n, 2)
    for i = 1:n
        if i <= n2 + 1
            v[i] = A[i,1]
        else
            v[i] = A[1, n - i + 2]
        end
    end
    return Circulant(v)
end

# Chan matrix
function chan{T}(A::AbstractMatrix{T})
    n = size(A, 1)
    v = Array(T, n)
    for i = 1:n
        v[i] = ((n - i + 1) * A[i, 1] + (i - 1) * A[1, min(n - i + 2, n)]) / n
    end
    return Circulant(v)
end

# Triangular Toeplitz matrix
type TriangularToeplitz{T<:Number} <: AbstractToeplitz{T}
    ve::Vector{T}
    uplo::Char
    k::Integer # length of the other dimension
    vcvr_dft::Vector{Complex{T}}
    tmp::Vector{Complex{T}}
    dft::Base.DFT.Plan
end

# Recast a Triangular Toeplitz matrix as a general Toeplitz matrix
function Toeplitz(A::TriangularToeplitz)
    if A.uplo == 'L'
        Toeplitz(A.ve,[A.ve[1];zeros(A.k-1)])
    else
        @assert A.uplo == 'U'
        Toeplitz([A.ve[1];zeros(A.k-1)], A.ve)
    end
end

# Ctor
function TriangularToeplitz{T<:Number}(ve::Vector{T}, uplo::Symbol, k = length(ve))
    n = length(ve)
    tmp = uplo == :L ? complex([ve; zeros(k-1)]) : complex([ve[1]; zeros(T, k-1); reverse(ve[2:end])])
    dft = plan_fft!(tmp)
    return TriangularToeplitz(ve, string(uplo)[1], k, dft * tmp, similar(tmp), dft)
end

# Size
function size(A::TriangularToeplitz, dim::Int)
    if (A.uplo == 'L' && dim == 1) || (A.uplo == 'U' && dim == 2)
        return length(A.ve)
    elseif (A.uplo == 'U' && dim == 1) || (A.uplo == 'L' && dim == 2)
        return A.k
    elseif dim > 2
        return 1
    else
        error("arraysize: dimension out of range")
    end
end

# Fetch an entry
function getindex{T}(A::TriangularToeplitz{T}, i::Integer, j::Integer)
    if i > size(A, 1) || j > size(A, 2)
      error("BoundsError()")
    end
    if A.uplo == 'L'
        return i >= j ? A.ve[i - j + 1] : zero(T)
    else
        return i <= j ? A.ve[j - i + 1] : zero(T)
    end
end

# Multiplication of two triangular Toeplitz matrices
function (*)(A::TriangularToeplitz, B::TriangularToeplitz)
    n = size(A, 1)
    if n != size(B, 1)
        throw(DimensionMismatch(""))
    end
    if A.uplo == B.uplo
        # TODO: This can be further sped up
        return TriangularToeplitz(conv(A.ve, B.ve)[1:n], A.uplo)
    end
    # return Triangular(full(A), A.uplo) * Triangular(full(B), B.uplo)
    # TODO: This can be further sped up
    return full(A) * full(B)
end

# Apply the conjugate transpose of a triangular Toeplitz matrix to a general column vector
Ac_mul_B(A::TriangularToeplitz, b::AbstractVector) =
    TriangularToeplitz(A.ve, A.uplo == 'U' ? :L : :U, k) * b

# NB! only valid for lower triangular
function smallinv{T}(A::TriangularToeplitz{T})
    if size(A, 1) != size(A, 2)
      error("Inverse: Rectangular case is not supported.")
    end
    n = size(A, 1)
    b = zeros(T, n)
    b[1] = 1 ./ A.ve[1]
    for k = 2:n
        tmp = zero(T)
        for i = 1:k-1
            tmp += A.uplo == 'L' ? A.ve[k - i + 1]*b[i] : A.ve[i + 1] * b[k - i]
        end
        b[k] = -tmp/A.ve[1]
    end
    return TriangularToeplitz(b, symbol(A.uplo))
end

function inv{T}(A::TriangularToeplitz{T})
    if size(A, 1) != size(A, 2)
      error("Inverse: Rectangular case is not supported.")
    end
    n = size(A, 1)
    if n <= 64
        return smallinv(A)
    end
    np2 = nextpow2(n)
    if n != np2
        return TriangularToeplitz(inv(TriangularToeplitz([A.ve, zeros(T, np2 - n)],
            symbol(A.uplo))).ve[1:n], symbol(A.uplo))
    end
    nd2 = div(n, 2)
    a1 = inv(TriangularToeplitz(A.ve[1:nd2], symbol(A.uplo))).ve
    return TriangularToeplitz([a1, -(TriangularToeplitz(a1, symbol(A.uplo)) *
        (Toeplitz(A.ve[nd2 + 1:end], A.ve[nd2 + 1:-1:2]) * a1))], symbol(A.uplo))
end

# A_ldiv_B!(A::TriangularToeplitz,b::StridedVector) = inv(A)*b
A_ldiv_B!(A::TriangularToeplitz, b::StridedVector) =
    copy!(b, IterativeLinearSolvers.cgs(A, zeros(length(b)), b, chan(A), 1000, 100eps())[1])

# extend levinson
StatsBase.levinson!(x::StridedVector, A::SymmetricToeplitz, b::StridedVector) =
    StatsBase.levinson!(A.ve, b, x)

function StatsBase.levinson!(C::StridedMatrix, A::SymmetricToeplitz, B::StridedMatrix)
    n = size(B, 2)
    if n != size(C, 2)
        throw(DimensionMismatch("input and output matrices must have same number of columns"))
    end
    for j = 1:n
        StatsBase.levinson!(sub(C, :, j), A, sub(B, :, j))
    end
    C
end

StatsBase.levinson(A::AbstractToeplitz, B::StridedVecOrMat) =
    StatsBase.levinson!(zeros(size(B)), A, copy(B))

# BlockTriangular
# type BlockTriangularToeplitz{T<:BlasReal} <: AbstractMatrix{T}
#     Mc::Array{T,3}
#     uplo::Char
#     Mc_dft::Array{Complex{T},3}
#     tmp::Vector{Complex{T}}
#     dft::Base.DFT.Plan
# end
# function BlockTriangularToeplitz{T<:BlasReal}(Mc::Array{T,3}, uplo::Symbol)
#     n, p, _ = size(Mc)
#     tmp = zeros(Complex{T}, 2n)
#     dft = plan_fft!(tmp)
#     Mc_dft = Array(Complex{T}, 2n, p, p)
#     for j = 1:p
#         for i = 1:p
#             Mc_dft[1,i,j] = complex(Mc[1,i,j])
#             for t = 2:n
#                 Mc_dft[t,i,j] = uplo == :L ? complex(Mc[t,i,j]) : zero(Complex{T})
#             end
#             Mc_dft[n+1,i,j] = zero(Complex{T})
#             for t = n+2:2n
#                 Mc_dft[t,i,j] = uplo == :L ? zero(Complex{T}) : complex(Mc[2n-t+2,i,j])
#             end
#             dft(sub(Mc_dft, 1:2n, 1:p, 1:p))
#         end
#     end
#     return BlockTriangularToeplitz(Mc, string(uplo)[1], Mc_dft, tmp, dft, idft)
# end

#= Hankel Matrix
 A Hankel matrix is a matrix that is constant across the anti-diagonals:

  [a_0 a_1 a_2 a_3 a_4
   a_1 a_2 a_3 a_4 a_5
   a_2 a_3 a_4 a_5 a_6]

 This is precisely a Toeplitz matrix with the columns reversed:
                             [0 0 0 0 1
  [a_4 a_3 a_2 a_1 a_0        0 0 0 1 0
   a_5 a_4 a_3 a_2 a_1   *    0 0 1 0 0
   a_6 a_5 a_4 a_3 a_2]       0 1 0 0 0
                              1 0 0 0 0]
 We represent the Hankel matrix by wrapping the corresponding Toeplitz matrix.=#

# Hankel Matrix
type Hankel{T<:Number} <: AbstractMatrix{T}
    T::Toeplitz{T}
end

# Ctor: vc is the leftmost column and vr is the bottom row.
function Hankel(vc,vr)
    if vc[end] != vr[1]
        error("First element of rows must equal last element of columns")
    end
    n = length(vr)
    p = [vc; vr[2:end]]
    Hankel(Toeplitz(p[n:end],p[n:-1:1]))
end

# Size
size(H::Hankel,k...) = size(H.T,k...)

# Full version of a Hankel matrix
function full{T}(A::Hankel{T})
    m, n = size(A)
    Af = Array(T, m, n)
    for j = 1:n
        for i = 1:m
            Af[i,j] = A[i,j]
        end
    end
    return Af
end

# Retrieve an entry by two indices
getindex(A::Hankel, i::Integer, j::Integer) = A.T[i,end-j+1]

# Retrieve an entry by one index
getindex(H::Hankel, i::Integer) = H[mod(i, size(H,1)), div(i, size(H,1)) + 1]

# Fast application of a general Hankel matrix to a general vector
*(A::Hankel,b::AbstractVector) = A.T * reverse(b)

# Fast application of a general Hankel matrix to a general matrix
*(A::Hankel,B::AbstractMatrix) = A.T * flipdim(B, 1)

# BigFloat support
(*){T<:BigFloat}(A::Toeplitz{T}, b::Vector) = irfft(
    rfft([
        A.vc;
        reverse(A.vr[2:end])]
    ) .* rfft([
        b;
        zeros(length(b) - 1)
    ]),
    2 * length(b) - 1
)[1:length(b)]

end
#module
