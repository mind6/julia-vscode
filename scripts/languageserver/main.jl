if VERSION < v"1.0.0"
    error("VS Code julia language server only works with julia 1.0.0+")
end

import Pkg
version_specific_env_path = joinpath(@__DIR__, "..", "environments", "languageserver", "v$(VERSION.major).$(VERSION.minor)")
if isdir(version_specific_env_path)
    Pkg.activate(version_specific_env_path)
else
    Pkg.activate(joinpath(@__DIR__, "..", "environments", "languageserver", "fallback"))
end

@info "Julia started at $(round(Int, time()))"

using Logging
global_logger(ConsoleLogger(stderr))

@info "Starting the Julia Language Server"

using InteractiveUtils, Sockets

include("../error_handler.jl")

struct LSPrecompileFailure <: Exception
    msg::AbstractString
end

function Base.showerror(io::IO, ex::LSPrecompileFailure)
    print(io, ex.msg)
end

try
    if length(Base.ARGS) != 8
        error("Invalid number of arguments passed to julia language server.")
    end

    #For debugging level, we want to avoid turning on debug for the julia interpreter, since it can cause world age issues. It's better to turn on debug logging level for specific modules or module_roots, instead of 'all'
    debug_arg = Base.ARGS[2]
    if startswith(debug_arg, "--debug=")
        ENV["JULIA_DEBUG"] = debug_arg[length("--debug=")+1:end]
    elseif !isempty(debug_arg)
        error("""Argument 2 will be used to set JULIA_DEBUG environment variable. It should look like "--debug=[all|module1,module1]" """)
    end
    @debug "LS arguments: " Base.ARGS       # @debug logging available from here

    detached_mode = if Base.ARGS[8] == "--detached=yes"
        true
    elseif Base.ARGS[8] == "--detached=no"
        false
    else
        error("Invalid argument passed.")
    end

    if detached_mode
        serv = listen(7777)
        global conn_in = accept(serv)
        global conn_out = conn_in
    else
        global conn_in = stdin
        global conn_out = stdout
        (outRead, outWrite) = redirect_stdout()
    end


    try
        using LanguageServer, SymbolServer
    catch err
        if err isa ErrorException && startswith(err.msg, "Failed to precompile")
            println(stderr, """\n
            The Language Server failed to precompile.
            Please make sure you have permissions to write to the LS depot path at
            \t$(ENV["JULIA_DEPOT_PATH"])
            """)
            throw(LSPrecompileFailure(err.msg))
        else
            rethrow(err)
        end
    end

    @debug "LanguageServer.jl loaded at $(round(Int, time()))"

    symserver_store_path = joinpath(ARGS[5], "symbolstorev5")
    # symserver_store_path = replace(symserver_store_path, "-"=>"_", "."=>"_")      #replace dots and dashes with underscore, or some packages won't load any symbols (tested on Windows 10)

    if !ispath(symserver_store_path)
        mkpath(symserver_store_path)
    end

    @info "Symbol server store is at '$symserver_store_path'."

    server = LanguageServerInstance(
        conn_in,
        conn_out,
        Base.ARGS[1],
        Base.ARGS[4],
        (err, bt) -> global_err_handler(err, bt, Base.ARGS[3], "Language Server"),
        symserver_store_path,
        ARGS[6] == "download",
        Base.ARGS[7]
    )
    @info "Starting LS at $(round(Int, time()))"
    run(server)
catch err
    global_err_handler(err, catch_backtrace(), Base.ARGS[3], "Language Server")
end
