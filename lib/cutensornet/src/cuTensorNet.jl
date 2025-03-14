module cuTensorNet

using LinearAlgebra
using CUDA
using CUDA: CUstream, cudaDataType, @checked, HandleCache, with_workspace
using CUDA: retry_reclaim, initialize_context, isdebug, cuDoubleComplex

using cuTENSOR
using cuTENSOR: CuTensor

using CEnum: @cenum

if CUDA.local_toolkit
    using CUDA_Runtime_Discovery
else
    import cuQuantum_jll
end

# XXX: cuTensorNet depends on cuTENSOR 1, while GC-safe ccalls were introduced in CUDA 5.3
#      which is only compatible with cuTENSOR 2. So disable that functionality for now.
const var"@gcsafe_ccall" = var"@ccall"
macro gcunsafe_callback(expr)
    esc(expr)
end


export has_cutensornet

const _initialized = Ref{Bool}(false)
has_cutensornet() = _initialized[]


const cudaDataType_t = cudaDataType

# core library
include("libcutensornet.jl")

include("error.jl")
include("types.jl")
include("tensornet.jl")

# cache for created, but unused handles
const idle_handles = HandleCache{CuContext,cutensornetHandle_t}()

function handle()
    cuda = CUDA.active_state()

    # every task maintains library state per device
    LibraryState = @NamedTuple{handle::cutensornetHandle_t}
    states = get!(task_local_storage(), :cuTensorNet) do
        Dict{CuContext,LibraryState}()
    end::Dict{CuContext,LibraryState}

    # get library state
    @noinline function new_state(cuda)
        new_handle = pop!(idle_handles, cuda.context) do
            handle = Ref{cutensornetHandle_t}()
            cutensornetCreate(handle)
            handle[]
        end

        finalizer(current_task()) do task
            push!(idle_handles, cuda.context, new_handle) do
                context!(cuda.context; skip_destroyed=true) do
                    cutensornetDestroy(new_handle)
                end
            end
        end

        (; handle=new_handle)
    end
    state = get!(states, cuda.context) do
        new_state(cuda)
    end

    return state.handle
end

function version()
  ver = cutensornetGetVersion()
  major, ver = divrem(ver, 10000)
  minor, patch = divrem(ver, 100)

  VersionNumber(major, minor, patch)
end

function cuda_version()
  ver = cutensornetGetCudartVersion()
  major, ver = divrem(ver, 1000)
  minor, patch = divrem(ver, 10)

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
    global libcutensornet
    if CUDA.local_toolkit
        dirs = CUDA_Runtime.find_toolkit()
        path = CUDA_Runtime.get_library(dirs, "cutensornet"; optional=true)
        if path === nothing
            precompiling || @error "cuQuantum is not available on your system (looked for cutensornet in $(join(dirs, ", ")))"
            return
        end
        libcutensornet = path
    else
        if !cuQuantum_jll.is_available()
            precompiling || @error "cuQuantum is not available for your platform ($(Base.BinaryPlatforms.triplet(cuQuantum_jll.host_platform)))"
            return
        end
        libcutensornet = cuQuantum_jll.libcutensornet
    end

    # register a log callback
    if isdebug(:init, cuTensorNet) || Base.JLOptions().debug_level >= 2
        callback = @cfunction(log_message, Nothing, (Int32, Cstring, Cstring))
        cutensornetLoggerSetCallback(callback)
        cutensornetLoggerOpenFile(Sys.iswindows() ? "NUL" : "/dev/null")
        cutensornetLoggerSetLevel(5)
    end

    _initialized[] = true
end

end
