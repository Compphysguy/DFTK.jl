using DFTK
using LinearAlgebra
using PyPlot

function test_convergence_forces_GP(d)

    # Nonlinearity : energy C ∫ρ^α
    C = 1.0
    α = 2

    # Unit cell. Having two lattice vectors as zero means a 1D system
    a = 1
    lattice = a .* [[1 0 0.]; [0 0 0]; [0 0 0]]

    ### potential
    # positions of the ions
    x1 = 0.15*a
    x2 = x1 + d*a
    # scale of the gaussian potential generated by the ions
    L = 0.05
    # ions
    pot_real(x) = exp(-(x/L)^2)
    pot_fourier(q::T) where {T <: Real} = exp(- (q*L)^2 / 4)
    ion = DFTK.WellIon(1, pot_real, pot_fourier)
    atoms = [ion => [x1*[1,0,0], x2*[1,0,0]]]

    n_electrons = 1  # increase this for fun
    # We add the needed terms
    terms = [Kinetic(),
             AtomicLocal(),
             PowerNonlinearity(C, α),
    ]
    model = Model(lattice; atoms=atoms, n_electrons=n_electrons, terms=terms,
                  spin_polarization=:spinless)  # "spinless fermions"

    # ref_solution
    Ecut_ref = 5000
    Ecut_list = 1000:500:4500
    basis_ref = PlaneWaveBasis(model, Ecut_ref)
    scfres_ref = self_consistent_field(basis_ref, tol=1e-12)
    F_ref = forces(scfres_ref)
    x = a * range(0, 1, length=basis_ref.fft_size[1]+1)[1:end-1]
    ρ = real(scfres_ref.ρ.real)[:, 1, 1] # converged density
    ψ_fourier = scfres_ref.ψ[1][:, 1] # first kpoint, all G components, first eigenvector
    ψ = G_to_r(basis_ref, basis_ref.kpoints[1], ψ_fourier)[:, 1, 1] # IFFT back to real space
    @assert sum(abs2.(ψ)) * (x[2]-x[1]) ≈ 1.0

    # phase fix
    ψ /= (ψ[div(end, 2)] / abs(ψ[div(end, 2)]))
    plot(x, DFTK.total_local_potential(scfres_ref.ham)[:,:,1], label = "pot")
    plot(x, real.(ψ), label="ψreal")
    plot(x, imag.(ψ), label="ψimag")
    plot(x, ρ, label="ρ")
    legend()

    h5open("GP_1D_forces.h5", "w") do file
        file["Ecut_list"] = collect(Ecut_list)
        file["forces_ref"] = F_ref[1][1][1]
        for Ecut in Ecut_list
            println("Ecut = $(Ecut)")
            basis = PlaneWaveBasis(model, Ecut)
            scfres = self_consistent_field(basis, tol=1e-12)
            F = forces(scfres)
            file["forces_Ecut$(Ecut)"] = F[1][1][1]
        end
    end
end
test_convergence_forces_GP(0.1)

figure(figsize=(10,10))
h5open("GP_1D_forces.h5", "r") do file
    F_ref = read(file["forces_ref"])
    Ecut_list = read(file["Ecut_list"])
    error_list = []
    for Ecut in Ecut_list
        F = read(file["forces_Ecut$(Ecut)"])
        push!(error_list, abs(F - F_ref))
    end
    semilogy(Ecut_list, error_list)
    xlabel("Ecut")
    ylabel("Fref - F")
    savefig("GP_1D_forces_Ecut.pdf")
end