function ChainRulesCore.rrule(
    ::typeof(linsolve),
    A::AbstractMatrix,
    b::AbstractVector,
    x₀,
    algorithm,
    a₀,
    a₁
)
    (x, info) = KrylovKit.linsolve(A, b, x₀, algorithm, a₀, a₁)
    project_A = ProjectTo(A)

    function linsolve_pullback(X̄)
        x̄ = unthunk(X̄[1])
        ∂self = NoTangent()
        ∂x₀ = ZeroTangent()
        ∂algorithm = NoTangent()
        ∂b, reverse_info = KrylovKit.linsolve(
            A', x̄, (zero(a₀) * zero(a₁)) * x̄, algorithm, conj(a₀), conj(a₁)
        )
        if info.converged > 0 && reverse_info.converged == 0
            @warn "The cotangent linear problem did not converge, whereas the primal linear problem did."
        end
        if A isa StridedMatrix
            ∂A = InplaceableThunk(
                Ā -> mul!(Ā, ∂b, x', -conj(a₁), true),
                @thunk(-conj(a₁) * ∂b * x'),
            )
        else
            ∂A = @thunk(project_A(-conj(a₁) * ∂b * x'))
        end
        ∂a₀ = @thunk(-dot(x, ∂b))
        if a₀ == zero(a₀) && a₁ == one(a₁)
            ∂a₁ = @thunk(-dot(b, ∂b))
        else
            ∂a₁ = @thunk(-dot((b - a₀ * x)/a₁, ∂b))
        end
        return ∂self, ∂A, ∂b, ∂x₀, ∂algorithm, ∂a₀, ∂a₁
    end
    return (x, info), linsolve_pullback
end

function ChainRulesCore.rrule(
    config::RuleConfig{>:HasReverseMode},
    ::typeof(linsolve),
    A::AbstractMatrix,
    b::AbstractVector,
    x₀,
    algorithm,
    a₀,
    a₁
)
    return rrule(linsolve, A, b, x₀, algorithm, a₀, a₁)
end

function ChainRulesCore.rrule(
    config::RuleConfig{>:HasReverseMode},
    ::typeof(linsolve),
    f,
    b,
    x₀,
    algorithm,
    a₀,
    a₁
)
    x, info = KrylovKit.linsolve(f, b, x₀, algorithm, a₀, a₁)

    # f defines a linear map => pullback defines action of the adjoint
    (y, f_pullback) = rrule_via_ad(config, f, x)
    fᴴ(xᴴ) = f_pullback(xᴴ)[2]
    # TODO can we avoid computing f_pullback if algorithm isa Union{CG,MINRES}?

    function linsolve_pullback(X̄)
        x̄ = unthunk(X̄[1])
        ∂self = NoTangent()
        ∂x₀ = ZeroTangent()
        ∂algorithm = NoTangent()
        (∂b, reverse_info) = KrylovKit.linsolve(
            fᴴ, x̄, (zero(a₀) * zero(a₁)) * x̄, algorithm, conj(a₀), conj(a₁)
        )
        if reverse_info.converged == 0
            @warn "Linear problem for reverse rule did not converge." reverse_info
        end
        ∂f = @thunk(f_pullback(-conj(a₁)*∂b)[1])
        ∂a₀ = @thunk(-dot(x, ∂b))
        # ∂a₁ = @thunk(-dot(f(x), ∂b))
        if a₀ == zero(a₀) && a₁ == one(a₁)
            ∂a₁ = @thunk(-dot(b, ∂b))
        else
            ∂a₁ = @thunk(-dot((b - a₀ * x)/a₁, ∂b))
        end
        return ∂self, ∂f, ∂b, ∂x₀, ∂algorithm, ∂a₀, ∂a₁
    end
    return (x, info), linsolve_pullback
end

# frule - currently untested

function ChainRulesCore.frule((_, ΔA, Δb, Δx₀, _, Δa₀, Δa₁)::Tuple, ::typeof(linsolve),
    A::AbstractMatrix, b::AbstractVector, x₀, algorithm, a₀, a₁)

    (x, info) = KrylovKit.linsolve(A, b, x₀, algorithm, a₀, a₁)

    if Δb isa ChainRulesCore.AbstractZero
        rhs = zero(b)
    else
        rhs = (1 - Δa₁)*Δb
    end
    if !iszero(Δa₀)
        rhs = axpy!(-Δa₀, x, rhs)
    end
    if !iszero(ΔA)
        rhs = mul!(rhs, ΔA, x, -a₁, true)
    end
    (Δx, forward_info) = KrylovKit.linsolve(A, rhs, zero(rhs), algorithm, a₀, a₁)
    if info.converged > 0 && forward_info.converged == 0
        @warn "The tangent linear problem did not converge, whereas the primal linear problem did."
    end
    return (x, info), (Δx, NoTangent())
end

function ChainRulesCore.frule(config::RuleConfig{>:HasForwardsMode}, tangents, ::typeof(linsolve),
    A::AbstractMatrix, b::AbstractVector, x₀, algorithm, a₀, a₁)
    frule(tangents, linsolve, A, b, x₀, algorithm, a₀, a₁)
end

function ChainRulesCore.frule(config::RuleConfig{>:HasForwardsMode}, (_, Δf, Δb, Δx₀, _, Δa₀, Δa₁),
    ::typeof(linsolve),
    f, b, x₀, algorithm, a₀, a₁)

    (x, info) = KrylovKit.linsolve(f, b, x₀, algorithm, a₀, a₁)

    if Δb isa AbstractZero
        rhs = false * b
    else
        rhs = (1 - Δa₁) * Δb
    end
    if !iszero(Δa₀)
        rhs = axpy!(-Δa₀, x, rhs)
    end
    if !(Δf isa AbstractZero)
        rhs = axpy!(-a₁, frule_via_ad(config, (Δf, ZeroTangent()), f, x), rhs)
    end
    (Δx, forward_info) = KrylovKit.linsolve(f, rhs, false*rhs, algorithm, a₀, a₁)
    if info.converged > 0 && forward_info.converged == 0
        @warn "The tangent linear problem did not converge, whereas the primal linear problem did."
    end
    return (x, info), (Δx, NoTangent())
end
