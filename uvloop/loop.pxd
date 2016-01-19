# cython: language_level=3


include "__debug.pxi" # Generated by "make"


from .includes cimport uv
from .includes cimport system

from libc.stdint cimport uint64_t


include "includes/consts.pxi"


cdef class UVHandle

cdef class UVAsync(UVHandle)
cdef class UVTimer(UVHandle)
cdef class UVSignal(UVHandle)
cdef class UVIdle(UVHandle)

ctypedef object (*method_t)(object ctx)


cdef class Loop:
    cdef:
        uv.uv_loop_t *uvloop

        bint _closed
        bint _debug
        bint _running
        bint _stopping

        long _thread_id
        bint _thread_is_main
        bint _sigint_check

        SignalsStack py_signals
        SignalsStack uv_signals
        bint _executing_py_code

        object _task_factory
        object _exception_handler
        object _default_executor
        object _ready
        Py_ssize_t _ready_len

        set _requests
        set _timers
        set _servers
        dict _polls
        dict _polls_gc

        UVAsync handler_async
        UVIdle handler_idle
        UVSignal handler_sigint
        UVSignal handler_sighup

        object _last_error

        cdef object __weakref__

        char _recv_buffer[UV_STREAM_RECV_BUF_SIZE]
        bint _recv_buffer_in_use

        IF DEBUG:
            object _debug_handles_total
            object _debug_handles_count

            uint64_t _debug_cb_handles_total
            uint64_t _debug_cb_handles_count
            uint64_t _debug_cb_timer_handles_total
            uint64_t _debug_cb_timer_handles_count

            uint64_t _debug_stream_write_ctx_total
            uint64_t _debug_stream_write_ctx_cnt

    cdef _on_wake(self)
    cdef _on_idle(self)
    cdef _on_sigint(self)
    cdef _on_sighup(self)

    cdef _check_sigint(self)

    cdef __run(self, uv.uv_run_mode)
    cdef _run(self, uv.uv_run_mode)

    cdef _close(self)
    cdef _stop(self, exc=*)
    cdef uint64_t _time(self)

    cdef _call_soon(self, object callback, object args)
    cdef _call_later(self, uint64_t delay, object callback, object args)

    cdef inline void __track_request__(self, UVRequest request)
    cdef inline void __untrack_request__(self, UVRequest request)

    cdef void _handle_exception(self, object ex)

    cdef inline _check_closed(self)
    cdef inline _check_thread(self)

    cdef _getaddrinfo(self, str host, int port,
                      int family, int type,
                      int proto, int flags,
                      int unpack)


include "cbhandles.pxd"

include "handles/handle.pxd"
include "handles/async_.pxd"
include "handles/idle.pxd"
include "handles/timer.pxd"
include "handles/signal.pxd"
include "handles/poll.pxd"
include "handles/stream.pxd"
include "handles/tcp.pxd"

include "request.pxd"

include "server.pxd"

include "os_signal.pxd"
