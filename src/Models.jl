module Models

using Dates
using Distributions
using Random
using Distributed

abstract type AbstractModel{T}
end

initialize( M::AbstractModel ) = error( "initialize not yet implemented for $(typeof(M))" )

update( M::AbstractModel{T}, y::T ) where {T} = error( "update not yet implemented for $(typeof(M))" )

function update( M::AbstractModel{T}, a::AbstractVector{T}; kwargs... ) where {T}
    for x in a
        update( M, x; kwargs... )
    end
end

Distributions.rand!( M::AbstractModel{T}, v::AbstractVector{T}, n::Int = length(v) ) where {T} =
    error( "rand not yet implemented for $(typeof(M))" )

function Base.rand( M::AbstractModel, n::Int; kwargs... )
    observations = zeros(n)
    Distributions.rand!( M, observations; kwargs... )
    return observations
end

Base.rand( ::Type{U} ) where {T,U <: AbstractModel{T}} = error( "rand not implemented for type $U" )

fit( M::AbstractModel ) = error( "fit not yet implemented for $(typeof(M))" )

struct FittableModel{T, U <: AbstractModel{T}, F <: Function} <: AbstractModel{T}
    model::U
    f::F
end

FittableModel( model::U, f::F ) where {T,U <: AbstractModel{T}, F} = FittableModel{T,U,F}( model, f )

function fit( model::FittableModel{T,U,F}; kwargs... ) where {T,U,F}
    model.f( model.model; kwargs... )
    return model
end

update( model::FittableModel{T}, y::T ) where {T} = update( model.model, y )

Base.rand( ::Type{FittableModel{T,U,F}}; fitfunction::F = F.instance, kwargs... ) where {T, U, F} =
    FittableModel( rand( U; kwargs... ), F.instance )

abstract type DatedModel{T} <: AbstractModel{Tuple{Date,T}}
end

update( model::DatedModel{T}, y::Tuple{Date,T} ) where {T} = error( "update not yet implemented for $(typeof(M))" )
    
date( M::DatedModel ) = error( "date not yet implemented for $(typeof(M))" )

mutable struct LogReturnModel{T <: AbstractModel{Float64}} <: DatedModel{Float64}
    model::T
    lastdate::Date
    lastprice::Float64
end

initialize( model::LogReturnModel ) = initialize( model.model )

function update( model::LogReturnModel, y::Tuple{Date,Float64} )
    update( model.model, log(y[2]/model.lastprice) )
    model.lastdate = y[1]
    model.lastprice = y[2]
end

function Distributions.rand!( model::LogReturnModel, v::AbstractVector{Float64}, n::Int = length(v) ) where {T}
    rand!( model.model, v, n=n )
    lastprice = model.lastprice
    for i = 1:n
        v[i] = lastprice *= exp( v[i] )
    end
end

Base.rand( ::Type{LogReturnModel{T}}; lastdate::Date = nothing, lastprice::Float64 = nothing, kwargs... ) where {T} =
    LogReturnModel( rand( T; kwargs... ), lastdate, lastprice )

function fit( model::LogReturnModel; kwargs... )
    fit( model.model; kwargs... )
    return model
end

date( model::LogReturnModel ) = model.lastdate

mutable struct MultiStartModel{T, U <: AbstractModel{T}} <: AbstractModel{T}
    models::Vector{U}
end

function Base.rand(
    ::Type{MultiStartModel{T,U}};
    seeds::AbstractVector{Int} = 1:1,
    kwargs...
) where {T, U <: AbstractModel{T}}
    models = U[]
    for seed in seeds
        Random.seed!( seed )
        push!( models, rand( U; kwargs... ) )
    end
    return MultiStartModel( models )
end

function update( model::MultiStartModel{T,U}, y::T ) where {T,U}
    for submodel in model.models
        update( submodel, y )
    end
end

function fit(
    model::MultiStartModel;
    modules::Vector{Symbol} = Symbol[],
    kwargs...
)
    if nprocs() == 1
        for submodel in model.models
            fit( submodel; kwargs... )
        end
    else
        
        # I don't know of a more convenient way to load all the modules we want
        futures = Future[]
        for pid in workers()
            for moduletoeval in modules
                push!( futures, remotecall( Core.eval, pid, Main, Expr(:using,Expr(:.,moduletoeval)) ) )
            end
        end
        for future in futures
            wait(future)
        end

        model.models = pmap( submodel -> fit( submodel; kwargs... ), model.models )
    end
    return model
end

mutable struct AdaptedModel{T,U <: AbstractModel{T}} <: DatedModel{T}
    modeldates::AbstractVector{Date}
    models::Vector{U}
    lastdate::Date
end

updatemodel( model::AbstractModel{T}, y::Tuple{Date, T} ) where {T} = update( model, y[2] )

function updatemodel( model::DatedModel{T}, y::Tuple{Date, T} ) where {T}
    @assert( date( model ) < y[1] )
    update( model, y )
end

function Base.rand( ::Type{AdaptedModel{T,U}}; modeldates::AbstractVector{Date} = Date[], kwargs... ) where {T,U}
    model = rand( U; kwargs... )
    return AdaptedModel( modeldates, [model], Date(0) )
end

function update( model::AdaptedModel{T,U}, y::Tuple{Date, T}; kwargs... ) where {T,U}
    date = y[1]
    updatemodel( model.models[end], y )

    index = length(model.models)
    if model.lastdate < model.modeldates[index] <= date
        println( "Fitting current model at $date" )
        fit( model.models[end]; kwargs... )
    end

    model.lastdate = date

    if index < length(model.modeldates) && date >= model.modeldates[index+1]
        @assert( length(model.models) == index )
        push!( model.models, deepcopy( model.models[end] ) )
        println( "Fitting next model at $date" )
        fit( model.models[end]; kwargs... )
    end
end

end # module
