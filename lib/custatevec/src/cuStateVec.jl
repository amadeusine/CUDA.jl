module cuStateVec

using CUDA
using CUDA: CUstream, cudaDataType, cudaEvent_t, @checked, HandleCache, with_workspace, libraryPropertyType
using CUDA: unsafe_free!, retry_reclaim, initialize_context, isdebug

using CEnum: @cenum

if CUDA.local_toolkit
    using CUDA_Runtime_Discovery
else
    import cuQuantum_jll
end

# XXX: cuStateVec depends on cuTENSOR 1, while GC-safe ccalls were introduced in CUDA 5.3
#      which is only compatible with cuTENSOR 2. So disable that functionality for now.
const var"@gcsafe_ccall" = var"@ccall"
macro gcunsafe_callback(expr)
    esc(expr)
end


export has_custatevec

const _initialized = Ref{Bool}(false)
has_custatevec() = _initialized[]


const cudaDataType_t = cudaDataType

# core library
include("libcustatevec.jl")

include("error.jl")
include("types.jl")
include("statevec.jl")

# cache for created, but unused handles
const idle_handles  = HandleCache{CuContext,custatevecHandle_t}()

function handle()
    cuda = CUDA.active_state()

    # every task maintains library state per device
    LibraryState = @NamedTuple{handle::custatevecHandle_t, stream::CuStream}
    states = get!(task_local_storage(), :CUQUANTUM) do
        Dict{CuContext,LibraryState}()
    end::Dict{CuContext,LibraryState}

    # get library state
    @noinline function new_state(cuda)
        new_handle = pop!(idle_handles, cuda.context) do
            handle = Ref{custatevecHandle_t}()
            custatevecCreate(handle)
            handle[]
        end

        finalizer(current_task()) do task
            push!(idle_handles, cuda.context, new_handle) do
                context!(cuda.context; skip_destroyed=true) do
                    custatevecDestroy(new_handle)
                end
            end
        end

        custatevecSetStream(new_handle, cuda.stream)

        (; handle=new_handle, cuda.stream)
    end
    state = get!(states, cuda.context) do
        new_state(cuda)
    end

    # update stream
    @noinline function update_stream(cuda, state)
        custatevecSetStream(state.handle, cuda.stream)
        (; state.handle, cuda.stream)
    end
    if state.stream != cuda.stream
        states[cuda.context] = state = update_stream(cuda, state)
    end

    return state.handle
end

function version()
  ver = custatevecGetVersion()
  major, ver = divrem(ver, 1000)
  minor, patch = divrem(ver, 100)

  VersionNumber(major, minor, patch)
end


## logging

@gcunsafe_callback function log_message(log_level, function_name, message)
    function_name = unsafe_string(function_name)
    message = unsafe_string(message)
    output = if isempty(message)
        "$function_name(...)"
    else
        "$function_name: $message"
    end
    if log_level <= 1
        @error output
    else
        # the other log levels are different levels of tracing and hints
        @debug output
    end
    return
end

function __init__()
    precompiling = ccall(:jl_generating_output, Cint, ()) != 0

    CUDA.functional() || return

    # find the library
    global libcustatevec
    if CUDA.local_toolkit
        dirs = CUDA_Runtime.find_toolkit()
        path = CUDA_Runtime.get_library(dirs, "custatevec"; optional=true)
        if path === nothing
            precompiling || @error "cuQuantum is not available on your system (looked for custatevec in $(join(dirs, ", ")))"
            return
        end
        libcustatevec = path
    else
        if !cuQuantum_jll.is_available()
            precompiling || @error "cuQuantum is not available for your platform ($(Base.BinaryPlatforms.triplet(cuQuantum_jll.host_platform)))"
            return
        end
        libcustatevec = cuQuantum_jll.libcustatevec
    end

    # register a log callback
    if !precompiling && (isdebug(:init, cuStateVec) || Base.JLOptions().debug_level >= 2)
        callback = @cfunction(log_message, Nothing, (Int32, Cstring, Cstring))
        custatevecLoggerSetCallback(callback)
        custatevecLoggerOpenFile(Sys.iswindows() ? "NUL" : "/dev/null")
        custatevecLoggerSetLevel(5)
    end

    _initialized[] = true
end

end
