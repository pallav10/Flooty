# Run without FlootySessions installed: julia --startup-file=no --project=. test/optionalSessionsProbe.jl
using Flooty
using UUIDs

sessionsId = Base.PkgId(UUID("963c42d5-230d-4615-aa6e-0698ef3b700d"), "FlootySessions")
@assert Base.locate_package(sessionsId) === nothing "This probe requires an environment without FlootySessions."
@assert !haskey(Base.loaded_modules, sessionsId)
@assert activeReplSession() === nothing
@assert deactivateReplTool!() === nothing
@assert !haskey(Base.loaded_modules, sessionsId)

mktempdir() do dir
    marker = joinpath(dir, "started")
    sidecar = joinpath(dir, "replacement.md")
    try
        err = try
            activateReplTool!(cmd = `/usr/bin/touch $marker`, sidecarPath = sidecar)
            nothing
        catch err
            err
        end
        @assert err isa ArgumentError
        @assert occursin("FlootySessions", sprint(showerror, err))
        @assert activeReplSession() === nothing
        @assert !ispath(marker) && !ispath(sidecar)
    finally
        deactivateReplTool!()
    end
end
@assert activeReplSession() === nothing
@assert deactivateReplTool!() === nothing
@assert !haskey(Base.loaded_modules, sessionsId)
println("PASS: missing optional FlootySessions fails before creating a PTY")
