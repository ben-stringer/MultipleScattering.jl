abstract type Simulation{T,Dim} end

mutable struct FrequencySimulation{T<:AbstractFloat,Dim,P<:PhysicalProperties} <: Simulation{T,Dim}
    medium::P
    particles::Particles{T,Dim}
    source::Source{P,T}
end

# Constructor which infers parametric types from input arguments, note that we
# don't need to do much type checking as the struct will error is inconsistent
function FrequencySimulation(medium::P, particles::Particles{T,Dim}, source::Source{P,T}) where {Dim,T,FieldDim,P<:PhysicalProperties{T,Dim,FieldDim}}
    FrequencySimulation{T,Dim,P}(medium, particles, source)
end

# A simulation with just sources is perfectly reasonable
function FrequencySimulation(medium::P, source::Source{P,T}) where {Dim,T,FieldDim,P<:PhysicalProperties{T,Dim,FieldDim}}
    FrequencySimulation{T,Dim,P}(medium, Vector{Particle{T,Dim,P,Shape}}(0), source)
end

import Base.run

# Main run function, all other run functions use this
function run(sim::FrequencySimulation{T,Dim,P}, x_vec::Vector{SVector{Dim,T}}, ω::T;
        basis_order::Int = 5) where {Dim,FieldDim,T,P<:PhysicalProperties{T,Dim,FieldDim}}

    # Calculate the Hankel coefficients around each particle, this is where most of the maths happens
    a_vec = basis_coefficients(sim, ω; basis_order=basis_order)

    # Evaluate the total field at the requested x positions
    field_vec = field(sim, ω, x_vec, a_vec; basis_order=basis_order)

    # Construct results object
    field_vec = reshape(map(f->SVector{FieldDim,Complex{T}}(f), field_vec), :, 1)
    return FrequencySimulationResult{T,Dim,FieldDim}(field_vec, x_vec, RowVector([ω]))

end

function run(sim::FrequencySimulation{T,Dim,P}, x_vec::Vector{SVector{Dim,T}}, ωs::AbstractVector{T};
        kws...)::(FrequencySimulationResult{T,Dim,FieldDim} where FieldDim)  where {Dim,P,T}
    # Compute for each angular frequency, then join up all the results
    fields = mapreduce(ω->run(sim,x_vec,ω; kws...).field, hcat, ωs)


    FrequencySimulationResult(fields,x_vec,RowVector(ωs))
end

function run(sim::FrequencySimulation{T,Dim,P}, x::SVector{Dim,T}, ωs::AbstractVector{T};
        kws...)::(FrequencySimulationResult{T,Dim,FieldDim} where FieldDim) where {Dim,P,T}
    run(sim,[x],ωs; kws...)
end

function run(sim::FrequencySimulation{T,Dim,P}, x::SVector{Dim,T}, ω::T;
        kws...)::(FrequencySimulationResult{T,Dim,FieldDim} where FieldDim) where {Dim,P,T}
    run(sim,[x],[ω]; kws...)
end

"""
simulate results over the whole `shape`. This SimulationResult can then be used by plot.
"""
function run(sim::FrequencySimulation, shape::Rectangle,
                              ω_vec::AbstractVector; res=20, xres=res, yres=res, kws...)

    #Size of the step in x and y direction
    step_size = [shape.width / xres, shape.height / yres]
    x_vec = [SVector(bottomleft(shape) + step_size.*[i,j]) for i=0:xres, j=0:yres]

    return run(sim, x_vec[:], ω_vec; kws...)
end

function forcing(source::Source{Ph,T}, particles::Particles, ω::T, Nh::Integer)::Vector{Complex{T}} where {Ph,T}
    mat = [source.coef(n,origin(p),ω) for n in -Nh:Nh, p in particles]
    f = Vector{Complex{T}}(prod(size(mat)))
    H = 2Nh + 1
    for i in eachindex(particles)
        f[((i-1)*H+1):(i*H)] .= mat[:,i]
    end
    return f
end

function basis_coefficients(sim::FrequencySimulation{T,Dim,P}, ω::T; basis_order::Int = 5) where {Dim,P,T}

    # Precompute T-matrices for these particles
    t_matrices = get_t_matrices(sim.medium, sim.particles, ω, basis_order)

    # Compute scattering matrix for all particles
    S = scattering_matrix(sim.medium, sim.particles, t_matrices, ω, basis_order)

    # Get forcing vector for this source
    f = forcing(sim.source, sim.particles, ω, basis_order)

    # Find Hankel coefficients by solving scattering matrix for this forcing
    a = S\f

    # reshape and multiply by t-matrix to get the scattering coefficients
    a = reshape(a,2basis_order+1,length(sim.particles))
    for i in indices(a,2)
        a[:,i] = t_matrices[i] * a[:,i]
    end
    a
end

function field(sim::FrequencySimulation{T,Dim,P}, ω::T, x_vec::Vector{SVector{Dim,T}}, a_vec; basis_order::Int=5) where {Dim,P,T}
    Nh = basis_order
    num_particles = length(sim.particles)
    a = OffsetArray(a_vec,-Nh:Nh,1:num_particles)
    basis = basis_function(sim.medium, ω)
    function sum_basis(x)
        sum(eachindex(sim.particles)) do i
            p = sim.particles[i]
            sum(-Nh:Nh) do m
                a[m,i] * basis(m, x-origin(p))
            end
        end
    end
    map(x_vec) do x
        ind = find(inside(p.shape, x) for p in sim.particles)
        if isempty(ind)
            sim.source.field(x,ω) + (isempty(sim.particles) ? zero(Complex{T}) : sum_basis(x))
        else
            j = ind[1]
            p = sim.particles[j]
            inner_basis = basis_function(p, ω)
            b_vec = inner_basis_coefficients(p, sim.medium, ω, collect(a[:,j]); basis_order=Nh)
            sum(-Nh:Nh) do m
                inner_basis(m, x-origin(p)) * b_vec[m+Nh+1]
            end
        end
    end
end
