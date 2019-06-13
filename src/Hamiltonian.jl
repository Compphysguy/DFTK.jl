"""
Structure identifying a Plane-Wave-discretized Hamiltonian.

The Hamiltonian is effectively a collection of terms and
can be applied in a k-Point block using `apply_fourier!`.
"""
struct Hamiltonian
    """The plane-wave basis X used to discretize the Hamiltonian"""
    basis

    """
    The kinetic term, typically a scaled Laplacian, -1/2 Δ
    It is expected that this object supports a
    ```
    apply_fourier!(out, kinetic, k, in)
    ```
    function call to compute its action at a particular k point.
    """
    kinetic

    """
    Term representing a local potential
    It is expected that this object supports a
    ```
    apply_real!(out, pot_local, in)
    ```
    function call, which should compute the action of the potential
    on the grid Y*. The potential should not depend on the density
    or the SCF orbitals.
    """
    pot_local

    """
    Term representing a non-local potential
    This object should support a
    ```
    apply_fourier!(out, pot_nonlocal, k, in)
    ```
    function call to compute its action at a particular k point.
    """
    pot_nonlocal

    """
    Term representing the Hartree potential
    This term will be applied on the grid Y* using the signature
    ```
    apply_real!(out, pot_local, precomp, in)
    ```
    where precomp is precomputed data which was obtained earlier
    by calling `precompute` on the object
    (e.g. `precompute(pot_hartree, ρ_Y)`).
    """
    pot_hartree

    """
    Term representing the exchange-correlation potential
    This term will be applied on the grid Y*, similar to
    pot_hartree, i.e. with a signature
    ```
    apply_real!(out, pot_local, precomp, in)
    ```
    """
    pot_xc
end


"""
Construct a Hamiltonian from a basis and various potential terms
"""
function Hamiltonian(kinetic::Kinetic; pot_local=nothing, pot_nonlocal=nothing,
            pot_hartree=nothing, pot_xc=nothing)
    Hamiltonian(kinetic.basis, kinetic, pot_local, pot_nonlocal,
                pot_hartree, pot_xc)
end


#=
function Hamiltonian(basis; kinetic=Kinetic(basis), pot_local=nothing, pot_nonlocal=nothing,
            pot_hartree=nothing, pot_xc=nothing)
    Hamiltonian(basis, kinetic, pot_local, pot_nonlocal,
                pot_hartree, pot_xc)
end
=#


"""
Construct a Hamiltonian from a list of potential terms
"""
function Hamiltonian(; pot_local=nothing, pot_nonlocal=nothing, pot_hartree=nothing,
                     pot_xc=nothing)
    basisobj = something(pot_nonlocal, pot_hartree, pot_xc, false)
    if basisobj == false
        error("At least one potenial terms needs to be given.")
    end
    Hamiltonian(Kinetic(basisobj.basis), pot_local=pot_local, pot_nonlocal=pot_nonlocal,
                pot_hartree=pot_hartree, pot_xc=pot_xc)
end


Base.eltype(ham::Hamiltonian) = Complex{eltype(ham.basis.lattice)}


"""
    apply_fourier!(out_k, ham, ik, precomp_hartree, precomp_xc, X_k)

Apply the `ik`-th k-point block of a Hamiltonian using precomputed data
for the Hartree and XC terms.

The application proceeds as follows:
    - The kinetic and non-local potential terms are applied directly
      in the plane-wave basis.
    - For the other terms we require the respective potential `V` on Y*
      and proceed using the protocol
         X_k --pad--> Y --IFFT--> Y* --V--> Y* --FFT--> Y --trunc--> X_k
      where the meaning is
         pad      Zero padding
         FFT      fast-Fourier transform
         IFFT     inverse fast-Fourier transform
         trunc    Truncation to a smaller basis
         V        Apply potential elementwise.
"""
function apply_fourier!(out_Xk::AbstractVector, ham::Hamiltonian, ik::Int, precomp_hartree,
                        precomp_xc, in_Xk::AbstractVector)
    pw = ham.basis

    # Apply kinetic and non-local potential if given, accumalate results
    tmp_Xk = similar(out_Xk)
    apply_fourier!(out_Xk, ham.kinetic, ik, in_Xk)
    out_Xk .+= apply_fourier!(tmp_Xk, ham.pot_nonlocal, ik, in_Xk)

    fft_terms = [ham.pot_local, ham.pot_hartree, ham.pot_xc]
    if any(term !== nothing for term in fft_terms)
        # If any of the terms requiring an iFFT is present, do an iFFT
        in_Yst = similar(in_Xk, size(pw.FFT)...)
        in_Yst = G_to_R!(pw, in_Xk, in_Yst, gcoords=pw.wf_basis[ik])

        # Apply the terms and accumulate
        accu_Yst = zero(in_Yst)
        tmp_Yst = similar(in_Yst)
        accu_Yst .+= apply_real!(tmp_Yst, ham.pot_local, in_Yst)
        accu_Yst .+= apply_real!(tmp_Yst, ham.pot_hartree, precomp_hartree, in_Yst)
        accu_Yst .+= apply_real!(tmp_Yst, ham.pot_xc, precomp_xc, in_Yst)

        # FFT back to Xk basis, accumlate, notice that this call
        # invalidates the data of accu_Yst as well.
        out_Xk .+= R_to_G!(pw, accu_Yst, tmp_Xk, gcoords=pw.wf_basis[ik])
    end
    out_Xk
end


function apply_fourier!(out_Xk, ham::Hamiltonian, ik::Int, precomp_hartree,
                        precomp_xc, in_Xk)
    # TODO This a fix for now to get it to work
    #      Ideally the above function should be able to deal with this directly
    n_bas, n_vec = size(in_Xk)
    for iv in 1:n_vec
        apply_fourier!(view(out_Xk, :, iv), ham, ik, precomp_hartree, precomp_xc,
                       view(in_Xk, :, iv))
    end
    out_Xk
end


# Specialisations of apply_fourier! and apply_real! for cases
# where nothing should be done.
apply_fourier!(out_Xk, op::Nothing, ik::Int, in_Xk) = (out_Xk .= 0)
"""Apply term staying on the real-space density grid ``B^∗_ρ``"""
apply_real!(out_Yst, op::Nothing, in_Yst) = (out_Yst .= 0)
apply_real!(out_Yst, op::Nothing, precomp, in_Yst) = (out_Yst .= 0)

# Specialisations of precompute for cases where nothing should be done
precompute!(precomp, op::Nothing, ρ_Y) = nothing
empty_precompute(op::Nothing) = nothing

# Get a representation of the Hamiltonian as a matrix
# TODO Is there a more julia-idiomatic way to do this?
function block_as_matrix(ham::Hamiltonian, ik::Int, precomp_hartree, precomp_xc)
    # TODO This assumes a PlaneWaveBasis
    n_bas = prod(ham.basis.grid_size)
    T = eltype(ham)
    mat = Matrix{T}(undef, (n_bas, n_bas))
    v = fill(zero(T), n_bas)
    @inbounds for i = 1:n_bas
        v[i] = one(T)
        apply_fourier!(view(mat, :, i), ham, ik, precomp_hartree, precomp_xc, v)
        v[i] = zero(T)
    end
return mat
end
