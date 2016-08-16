
#
# Conjugate gradient
#
# This is an independent implementation of:
#   W. W. Hager and H. Zhang (2006) Algorithm 851: CG_DESCENT, a
#     conjugate gradient method with guaranteed descent. ACM
#     Transactions on Mathematical Software 32: 113–137.
#
# Code comments such as "HZ, stage X" or "HZ, eqs Y" are with
# reference to a particular point in this paper.
#
# Several aspects of the following have also been incorporated:
#   W. W. Hager and H. Zhang (2012) The limited memory conjugate
#     gradient method.
#
# This paper will be denoted HZ2012 below.
#
# There are some modifications and/or extensions from what's in the
# paper (these may or may not be extensions of the cg_descent code
# that can be downloaded from Hager's site; his code has undergone
# numerous revisions since publication of the paper):
#
# cgdescent: the termination condition employs a "unit-correct"
#   expression rather than a condition on gradient
#   components---whether this is a good or bad idea will require
#   additional experience, but preliminary evidence seems to suggest
#   that it makes "reasonable" choices over a wider range of problem
#   types.
#
# linesearch: the Wolfe conditions are checked only after alpha is
#   generated either by quadratic interpolation or secant
#   interpolation, not when alpha is generated by bisection or
#   expansion. This increases the likelihood that alpha will be a
#   good approximation of the minimum.
#
# linesearch: In step I2, we multiply by psi2 only if the convexity
#   test failed, not if the function-value test failed. This
#   prevents one from going uphill further when you already know
#   you're already higher than the point at alpha=0.
#
# both: checks for Inf/NaN function values
#
# both: support maximum value of alpha (equivalently, c). This
#   facilitates using these routines for constrained minimization
#   when you can calculate the distance along the path to the
#   disallowed region. (When you can't easily calculate that
#   distance, it can still be handled by returning Inf/NaN for
#   exterior points. It's just more efficient if you know the
#   maximum, because you don't have to test values that won't
#   work.) The maximum should be specified as the largest value for
#   which a finite value will be returned.  See, e.g., limits_box
#   below.  The default value for alphamax is Inf. See alphamaxfunc
#   for cgdescent and alphamax for linesearch_hz.


immutable ConjugateGradient{T} <: Optimizer
    eta::Float64
    P::T
    precondprep!::Function
    linesearch!::Function
end

function ConjugateGradient(;
                           linesearch!::Function = hz_linesearch!,
                           eta::Real = 0.4,
                           P::Any = nothing,
                           precondprep! = (P, x) -> nothing)
    ConjugateGradient{typeof(P)}(Float64(eta),
                                 P, precondprep!,
                                 linesearch!)
end

method_string(method::ConjugateGradient) = "Conjugate Gradient"

type ConjugateGradientState{T}
    n::Int64
    x::Array{T}
    x_previous::Array{T}
    y::Array{T}
    py::Array{T}
    pg::Array{T}
    g::Array{T}
    g_previous::Array{T}
    f_x::T
    f_x_previous::T
    s::Array{T}
    x_ls::Array{T}
    g_ls::Array{T}
    alpha::T
    mayterminate::Bool
    f_calls::Int64
    g_calls::Int64
    lsr
end


function initialize_state{T}(method::ConjugateGradient, options, d, initial_x::Array{T})
    g = similar(initial_x)
    f_x = d.fg!(initial_x, g)
    pg = copy(g)
    s = similar(initial_x)
    @assert typeof(f_x) == T
    # Output messages
    if !isfinite(f_x)
        error("Must have finite starting value")
    end
    if !all(isfinite(g))
        @show g
        @show find(!isfinite(g))
        error("Gradient must have all finite values at starting point")
    end

    # Determine the intial search direction
    #    if we don't precondition, then this is an extra superfluous copy
    #    TODO: consider allowing a reference for pg instead of a copy
    method.precondprep!(method.P, initial_x)
    A_ldiv_B!(pg, method.P, g)
    scale!(copy!(s, pg), -1)

    ConjugateGradientState(length(initial_x),
                         copy(initial_x), # Maintain current state in state.x
                         copy(initial_x), # Maintain current state in state.x_previous
                         similar(initial_x), # Intermediate value in CG calculation
                         similar(initial_x), # Preconditioned intermediate value in CG calculation
                         pg, # Maintain the preconditioned gradient in pg
                         g, # Store current gradient in state.g
                         copy(g), # Store previous gradient in state.g_previous
                         f_x, # Store current f in state.f_x
                         T(NaN), # Store previous f in state.f_x_previous
                         s, # Maintain current search direction in state.s
                         similar(initial_x), # Buffer of x for line search in state.x_ls
                         similar(initial_x), # Buffer of g for line search in state.g_ls
                         alphainit(one(T), initial_x, g, f_x), # Keep track of step size in state.alpha
                         false, # state.mayterminate
                         1, # Track f calls in state.f_calls
                         1, # Track g calls in state.g_calls
                         LineSearchResults(T)) # Maintain a cache for line search results in state.lsr
end

function update!{T}(df, state::ConjugateGradientState{T}, method::ConjugateGradient)
        # Reset the search direction if it becomes corrupted
        dphi0 = vecdot(state.g, state.s)
        if dphi0 >= 0
            @simd for i in 1:state.n
                @inbounds state.s[i] = -state.pg[i]
            end
            dphi0 = vecdot(state.g, state.s)
            if dphi0 >= 0
                return true
            end
        end

        # Refresh the line search cache
        clear!(state.lsr)
        @assert typeof(state.f_x) == T
        @assert typeof(dphi0) == T
        push!(state.lsr, zero(T), state.f_x, dphi0)

        # Pick the initial step size (HZ #I1-I2)
        state.alpha, state.mayterminate, f_update, g_update =
          alphatry(state.alpha, df, state.x, state.s, state.x_ls, state.g_ls, state.lsr)
        state.f_calls, state.g_calls = state.f_calls + f_update, state.g_calls + g_update

        # Determine the distance of movement along the search line
        state.alpha, f_update, g_update =
          method.linesearch!(df, state.x, state.s, state.x_ls, state.g_ls, state.lsr, state.alpha, state.mayterminate)
        state.f_calls, state.g_calls = state.f_calls + f_update, state.g_calls + g_update

        # Maintain a record of previous position
        copy!(state.x_previous, state.x)

        # Update current position # x = x + alpha * s
        LinAlg.axpy!(state.alpha, state.s, state.x)

        # Maintain a record of the previous gradient
        copy!(state.g_previous, state.g)

        # Update the function value and gradient
        state.f_x_previous, state.f_x = state.f_x, df.fg!(state.x, state.g)
        state.f_calls, state.g_calls = state.f_calls + 1, state.g_calls + 1

        # Check sanity of function and gradient
        if !isfinite(state.f_x)
            error("Function must finite function values")
        end

        # Determine the next search direction using HZ's CG rule
        #  Calculate the beta factor (HZ2012)
        # -----------------
        # Comment on py: one could replace the computation of py with
        #    ydotpgprev = vecdot(y, pg)
        #    vecdot(y, py)  >>>  vecdot(y, pg) - ydotpgprev
        # but I am worried about round-off here, so instead we make an
        # extra copy, which is probably minimal overhead.
        # -----------------
        method.precondprep!(method.P, state.x)
        dPd = dot(state.s, method.P, state.s)
        etak::T = method.eta * vecdot(state.s, state.g_previous) / dPd
        @simd for i in 1:state.n
            @inbounds state.y[i] = state.g[i] - state.g_previous[i]
        end
        ydots = vecdot(state.y, state.s)
        copy!(state.py, state.pg)        # below, store pg - pg_previous in py
        A_ldiv_B!(state.pg, method.P, state.g)
        @simd for i in 1:state.n     # py = pg - py
           @inbounds state.py[i] = state.pg[i] - state.py[i]
        end
        betak = (vecdot(state.y, state.pg) - vecdot(state.y, state.py) * vecdot(state.g, state.s) / ydots) / ydots
        beta = max(betak, etak)
        @simd for i in 1:state.n
            @inbounds state.s[i] = beta * state.s[i] - state.pg[i]
        end
        false
end
