# cython: language_level=3


include "__debug.pxi" # Generated by "make"


cimport cython

from .includes cimport uv
from .includes cimport system
from .includes.python cimport PyMem_Malloc, PyMem_Free, \
                              PyMem_Calloc, PyMem_Realloc

from libc.stdint cimport uint64_t
from libc.string cimport memset

from cpython cimport PyObject
from cpython cimport PyErr_CheckSignals, PyErr_Occurred
from cpython cimport PyThread_get_thread_ident
from cpython cimport Py_INCREF, Py_DECREF, Py_XDECREF, Py_XINCREF
from cpython cimport PyObject_GetBuffer, PyBuffer_Release, PyBUF_SIMPLE, \
                     Py_buffer
from cpython cimport PyErr_CheckSignals


include "includes/consts.pxi"
include "includes/stdlib.pxi"

include "errors.pyx"


cdef Loop __main_loop__ = None


@cython.no_gc_clear
cdef class Loop:
    def __cinit__(self):
        cdef int err

        # Install PyMem* memory allocators if they aren't installed yet.
        __install_pymem()

        self.uvloop = <uv.uv_loop_t*> \
                            PyMem_Malloc(sizeof(uv.uv_loop_t))
        if self.uvloop is NULL:
            raise MemoryError()

        self._closed = 0
        self._debug = 0
        self._thread_is_main = 0
        self._thread_id = 0
        self._running = 0
        self._stopping = 0

        self._sigint_check = 0

        self._requests = set()
        self._timers = set()
        self._servers = set()
        self._polls = dict()
        self._polls_gc = dict()

        if MAIN_THREAD_ID == PyThread_get_thread_ident():  # XXX
            self.py_signals = SignalsStack()
            self.uv_signals = SignalsStack()

            self.py_signals.save()
        else:
            self.py_signals = None
            self.uv_signals = None

        self._executing_py_code = 0

        self._recv_buffer_in_use = 0

        err = uv.uv_loop_init(self.uvloop)
        if err < 0:
            raise convert_error(err)
        self.uvloop.data = <void*> self

        IF DEBUG:
            self._debug_handles_count = col_Counter()
            self._debug_handles_total = col_Counter()

            self._debug_stream_write_ctx_total = 0
            self._debug_stream_write_ctx_cnt = 0

            self._debug_cb_handles_total = 0
            self._debug_cb_handles_count = 0

            self._debug_cb_timer_handles_total = 0
            self._debug_cb_timer_handles_count = 0

        self._last_error = None

        self._task_factory = None
        self._exception_handler = None
        self._default_executor = None

        self._ready = col_deque()
        self._ready_len = 0

        self.handler_async = UVAsync.new(
            self, <method_t*>&self._on_wake, self)

        self.handler_idle = UVIdle.new(
            self, <method_t*>&self._on_idle, self)

        self.handler_sigint = UVSignal.new(
            self, <method_t*>&self._on_sigint, self, uv.SIGINT)

        self.handler_sighup = UVSignal.new(
            self, <method_t*>&self._on_sighup, self, uv.SIGHUP)

    def __init__(self):
        self.set_debug((not sys_ignore_environment
                        and bool(os_environ.get('PYTHONASYNCIODEBUG'))))

    def __dealloc__(self):
        if self._running == 1:
            raise SystemExit('deallocating a running event loop!')
        if self._closed == 0:
            aio_logger.error("deallocating an active libuv loop")
        PyMem_Free(self.uvloop)
        self.uvloop = NULL

    cdef _on_wake(self):
        if (self._ready_len > 0 or self._stopping) \
                            and not self.handler_idle.running:
            self.handler_idle.start()

    cdef _on_sigint(self):
        try:
            PyErr_CheckSignals()
        except KeyboardInterrupt as ex:
            self._stop(ex)
        else:
            self._stop(KeyboardInterrupt())

    cdef _on_sighup(self):
        self._stop(SystemExit())

    cdef _check_sigint(self):
        self.uv_signals.save()
        __signal_set_sigint()

    cdef _on_idle(self):
        cdef:
            int i, ntodo
            object popleft = self._ready.popleft
            Handle handler

        if self._sigint_check == 0 and self._thread_is_main == 1:
            self._sigint_check = 1
            self._check_sigint()

        ntodo = len(self._ready)
        for i from 0 <= i < ntodo:
            handler = <Handle> popleft()
            if handler.cancelled == 0:
                try:
                    handler._run()
                except BaseException as ex:
                    self._stop(ex)
                    return

        if len(self._polls_gc):
            for fd in tuple(self._polls_gc):
                poll = <UVPoll> self._polls_gc[fd]
                if not poll.is_active():
                    poll._close()
                    self._polls.pop(fd)
                self._polls_gc.pop(fd)

        self._ready_len = len(self._ready)
        if self._ready_len == 0 and self.handler_idle.running:
            self.handler_idle.stop()

        if self._stopping:
            uv.uv_stop(self.uvloop)  # void

    cdef _stop(self, exc=None):
        if exc is not None:
            self._last_error = exc
        if self._stopping == 1:
            return
        self._stopping = 1
        if not self.handler_idle.running:
            self.handler_idle.start()

    cdef inline void __track_request__(self, UVRequest request):
        """Internal helper for tracking UVRequests."""
        self._requests.add(request)

    cdef inline void __untrack_request__(self, UVRequest request):
        """Internal helper for tracking UVRequests."""
        self._requests.remove(request)

    cdef __run(self, uv.uv_run_mode mode):
        global __main_loop__

        if self.py_signals is not None:
            __main_loop__ = self

        with nogil:
            err = uv.uv_run(self.uvloop, mode)

        if self.py_signals is not None:
            self.py_signals.restore()
            __main_loop__ = None

        if err < 0:
            raise convert_error(err)

    cdef _run(self, uv.uv_run_mode mode):
        cdef int err

        if self._closed == 1:
            raise RuntimeError('unable to start the loop; it was closed')

        if self._running == 1:
            raise RuntimeError('Event loop is running.')

        # reset _last_error
        self._last_error = None

        self._thread_id = PyThread_get_thread_ident()
        self._thread_is_main = MAIN_THREAD_ID == self._thread_id
        self._sigint_check = 0
        self._running = 1
        self._executing_py_code = 0

        self.handler_idle.start()
        self.handler_sigint.start()
        self.handler_sighup.start()

        self.__run(mode)

        self.handler_idle.stop()
        self.handler_sigint.stop()
        self.handler_sighup.stop()

        self._sigint_check = 0
        self._thread_is_main = 0
        self._thread_id = 0
        self._running = 0
        self._stopping = 0

        if self._last_error is not None:
            # The loop was stopped with an error with 'loop._stop(error)' call
            raise self._last_error

    cdef _close(self):
        cdef int err

        if self._running == 1:
            raise RuntimeError("Cannot close a running event loop")

        if self._closed == 1:
            return

        self._closed = 1

        for cb_handle in self._ready:
            cb_handle.cancel()
        self._ready.clear()
        self._ready_len = 0

        if self._servers: # XXX
            for srv in self._servers:
                (<UVHandle>srv)._close()
            self._servers.clear()

        if self._polls:
            for poll_handle in self._polls.values():
                (<UVHandle>poll_handle)._close()

            self._polls.clear()
            self._polls_gc.clear()

        if self._requests:
            for request in tuple(self._requests):
                (<UVRequest>request).cancel()

        if self._timers:
            for timer_cbhandle in tuple(self._timers):
                timer_cbhandle.cancel()

        __close_all_handles(self)

        # Allow loop to fire "close" callbacks
        self.__run(uv.UV_RUN_DEFAULT)

        if self._timers:
            raise RuntimeError(
                "new timers were queued during loop closing: {}"
                    .format(self._timers))

        if self._polls:
            raise RuntimeError(
                "new poll handles were queued during loop closing: {}"
                    .format(self._polls))

        if self._requests:
            raise RuntimeError(
                "new requests were queued or old requests weren't completed "
                "during loop closing: {}".format(self._requests))

        if self._ready:
            raise RuntimeError(
                "new callbacks were queued during loop closing: {}"
                    .format(self._ready))

        err = uv.uv_loop_close(self.uvloop)
        if err < 0:
            raise convert_error(err)

        self.handler_async = None
        self.handler_idle = None
        self.handler_sigint = None
        self.handler_sighup = None

        executor = self._default_executor
        if executor is not None:
            self._default_executor = None
            executor.shutdown(wait=False)

    cdef uint64_t _time(self):
        return uv.uv_now(self.uvloop)

    cdef _call_soon(self, object callback, object args):
        self._check_closed()
        handle = Handle(self, callback, args)
        self._ready.append(handle)
        self._ready_len += 1;
        if not self.handler_idle.running:
            self.handler_idle.start()
        return handle

    cdef _call_later(self, uint64_t delay, object callback, object args):
        return TimerHandle(self, callback, args, delay)

    cdef void _handle_exception(self, object ex):
        if isinstance(ex, Exception):
            self.call_exception_handler({'exception': ex})
        else:
            # BaseException
            self._last_error = ex
            # Exit ASAP
            self._stop()

    cdef inline _check_closed(self):
        if self._closed == 1:
            raise RuntimeError('Event loop is closed')

    cdef inline _check_thread(self):
        if self._thread_id == 0:
            return
        cdef long thread_id = PyThread_get_thread_ident()
        if thread_id != self._thread_id:
            raise RuntimeError(
                "Non-thread-safe operation invoked on an event loop other "
                "than the current one")

    cdef _getaddrinfo(self, str host, int port,
                      int family, int type,
                      int proto, int flags,
                      int unpack):

        fut = aio_Future(loop=self)

        def callback(result):
            if AddrInfo.isinstance(result):
                try:
                    if unpack == 0:
                        data = result
                    else:
                        data = (<AddrInfo>result).unpack()
                except Exception as ex:
                    if not fut.cancelled():
                        fut.set_exception(ex)
                else:
                    if not fut.cancelled():
                        fut.set_result(data)
            else:
                fut.set_exception(result)

        AddrInfoRequest(self, host, port, family, type, proto, flags, callback)
        return fut

    def _sock_recv(self, fut, registered, sock, n):
        # _sock_recv() can add itself as an I/O callback if the operation can't
        # be done immediately. Don't use it directly, call sock_recv().
        fd = sock.fileno()
        if registered:
            # Remove the callback early.  It should be rare that the
            # selector says the fd is ready but the call still returns
            # EAGAIN, and I am willing to take a hit in that case in
            # order to simplify the common case.
            self.remove_reader(fd)
        if fut.cancelled():
            return
        try:
            data = sock.recv(n)
        except (BlockingIOError, InterruptedError):
            self.add_reader(fd, self._sock_recv, fut, True, sock, n)
        except Exception as exc:
            fut.set_exception(exc)
        else:
            fut.set_result(data)

    def _sock_sendall(self, fut, registered, sock, data):
        fd = sock.fileno()

        if registered:
            self.remove_writer(fd)
        if fut.cancelled():
            return

        try:
            n = sock.send(data)
        except (BlockingIOError, InterruptedError):
            n = 0
        except Exception as exc:
            fut.set_exception(exc)
            return

        if n == len(data):
            fut.set_result(None)
        else:
            if n:
                data = data[n:]
            self.add_writer(fd, self._sock_sendall, fut, True, sock, data)

    def _sock_accept(self, fut, registered, sock):
        fd = sock.fileno()
        if registered:
            self.remove_reader(fd)
        if fut.cancelled():
            return
        try:
            conn, address = sock.accept()
            conn.setblocking(False)
        except (BlockingIOError, InterruptedError):
            self.add_reader(fd, self._sock_accept, fut, True, sock)
        except Exception as exc:
            fut.set_exception(exc)
        else:
            fut.set_result((conn, address))

    def _sock_connect(self, fut, sock, address):
        fd = sock.fileno()
        try:
            sock.connect(address)
        except (BlockingIOError, InterruptedError):
            # Issue #23618: When the C function connect() fails with EINTR, the
            # connection runs in background. We have to wait until the socket
            # becomes writable to be notified when the connection succeed or
            # fails.
            fut.add_done_callback(ft_partial(self._sock_connect_done, fd))
            self.add_writer(fd, self._sock_connect_cb, fut, sock, address)
        except Exception as exc:
            fut.set_exception(exc)
        else:
            fut.set_result(None)

    def _sock_connect_done(self, fd, fut):
        self.remove_writer(fd)

    def _sock_connect_cb(self, fut, sock, address):
        if fut.cancelled():
            return

        try:
            err = sock.getsockopt(uv.SOL_SOCKET, uv.SO_ERROR)
            if err != 0:
                # Jump to any except clause below.
                raise OSError(err, 'Connect call failed %s' % (address,))
        except (BlockingIOError, InterruptedError):
            # socket is still registered, the callback will be retried later
            pass
        except Exception as exc:
            fut.set_exception(exc)
        else:
            fut.set_result(None)

    # Public API

    IF DEBUG:
        def print_debug_info(self):
            cdef:
                int err
                uv.uv_rusage_t rusage
            err = uv.uv_getrusage(&rusage)
            if err < 0:
                raise convert_error(err)

            ################### OS

            print('---- Process info: -----')
            print('Process memory:    ', rusage.ru_maxrss)
            print('Number of signals: ', rusage.ru_nsignals)
            print('')

            ################### Loop

            print('--- Loop debug info: ---')
            print('Loop time:        {}'.format(self.time()))
            print()

            print('UVHandles (current | total):')
            for name in sorted(self._debug_handles_total):
                print('    {: <18} {: >5} | {}'.format(
                    name,
                    self._debug_handles_count[name],
                    self._debug_handles_total[name]))
            print()

            print('Write contexts:   {: >5} | {}'.format(
                self._debug_stream_write_ctx_cnt,
                self._debug_stream_write_ctx_total))
            print()

            print('Callback handles: {: >5} | {}'.format(
                self._debug_cb_handles_count,
                self._debug_cb_handles_total))
            print('Timer handles:    {: >5} | {}'.format(
                self._debug_cb_timer_handles_count,
                self._debug_cb_timer_handles_total))
            print()

            print('------------------------')
            print(flush=True)

    def __repr__(self):
        return ('<%s running=%s closed=%s debug=%s>'
                % (self.__class__.__name__, self.is_running(),
                   self.is_closed(), self.get_debug()))

    def call_soon(self, callback, *args):
        if self._debug == 1:
            self._check_thread()
        if not args:
            args = None
        return self._call_soon(callback, args)

    def call_soon_threadsafe(self, callback, *args):
        if not args:
            args = None
        handle = self._call_soon(callback, args)
        self.handler_async.send()
        return handle

    def call_later(self, delay, callback, *args):
        self._check_closed()
        if self._debug == 1:
            self._check_thread()
        if delay < 0:
            delay = 0
        cdef uint64_t when = <uint64_t>(delay * 1000)
        if not args:
            args = None
        if when == 0:
            return self._call_soon(callback, args)
        else:
            return self._call_later(when, callback, args)

    def call_at(self, when, callback, *args):
        return self.call_later(when - self.time(), callback, *args)

    def time(self):
        return self._time() / 1000

    def stop(self):
        self._call_soon(lambda: self._stop(), None)

    def run_forever(self):
        self._check_closed()
        mode = uv.UV_RUN_DEFAULT
        if self._stopping:
            # loop.stop() was called right before loop.run_forever().
            # This is how asyncio loop behaves.
            mode = uv.UV_RUN_NOWAIT
        self._run(mode)

    def close(self):
        self._close()

    def get_debug(self):
        if self._debug == 1:
            return True
        else:
            return False

    def set_debug(self, enabled):
        if enabled:
            self._debug = 1
        else:
            self._debug = 0

    def is_running(self):
        if self._running == 0:
            return False
        else:
            return True

    def is_closed(self):
        if self._closed == 0:
            return False
        else:
            return True

    def create_task(self, coro):
        self._check_closed()
        if self._task_factory is None:
            task = aio_Task(coro, loop=self)
            if task._source_traceback:
                del task._source_traceback[-1]
        else:
            task = self._task_factory(self, coro)
        return task

    def set_task_factory(self, factory):
        if factory is not None and not callable(factory):
            raise TypeError('task factory must be a callable or None')
        self._task_factory = factory

    def get_task_factory(self):
        return self._task_factory

    def run_until_complete(self, future):
        self._check_closed()

        new_task = not isinstance(future, aio_Future)
        future = aio_ensure_future(future, loop=self)
        if new_task:
            # An exception is raised if the future didn't complete, so there
            # is no need to log the "destroy pending task" message
            future._log_destroy_pending = False

        done_cb = lambda fut: self.stop()

        future.add_done_callback(done_cb)
        try:
            self.run_forever()
        except:
            if new_task and future.done() and not future.cancelled():
                # The coroutine raised a BaseException. Consume the exception
                # to not log a warning, the caller doesn't have access to the
                # local task.
                future.exception()
            raise
        future.remove_done_callback(done_cb)
        if not future.done():
            raise RuntimeError('Event loop stopped before Future completed.')

        return future.result()

    def getaddrinfo(self, str host, int port, *,
                    int family=0, int type=0, int proto=0, int flags=0):

        return self._getaddrinfo(host, port, family, type, proto, flags, 1)

    @aio_coroutine
    async def create_server(self, protocol_factory, str host, int port,
                            *,
                            int family=uv.AF_UNSPEC,
                            int flags=uv.AI_PASSIVE,
                            sock=None,
                            int backlog=100,
                            ssl=None,            # not implemented
                            reuse_address=None,  # ignored, libuv sets it
                            reuse_port=None):    # ignored

        cdef:
            UVTCPServer tcp
            system.addrinfo *addrinfo
            Server server = Server(self)

        if ssl is not None:
            raise NotImplementedError('SSL is not yet supported')

        if host is not None or port is not None:
            if sock is not None:
                raise ValueError(
                    'host/port and sock can not be specified at the same time')

            if host == '':
                hosts = [None]
            elif (isinstance(host, str) or not isinstance(host, col_Iterable)):
                hosts = [host]
            else:
                hosts = host

            fs = [self._getaddrinfo(host, port, family,
                                    uv.SOCK_STREAM, 0, flags,
                                    0) for host in hosts]

            infos = await aio_gather(*fs, loop=self)

            completed = False
            try:
                for info in infos:
                    addrinfo = (<AddrInfo>info).data
                    while addrinfo != NULL:
                        tcp = UVTCPServer.new(self, protocol_factory, server)
                        tcp.bind(addrinfo.ai_addr)
                        tcp.listen(backlog)

                        server._add_server(tcp)

                        addrinfo = addrinfo.ai_next

                completed = True
            finally:
                if not completed:
                    server.close()
        else:
            tcp = UVTCPServer.new(self, protocol_factory, server)
            tcp.open(sock.fileno())
            tcp.listen(backlog)
            server._add_server(tcp)

        return server

    def default_exception_handler(self, context):
        message = context.get('message')
        if not message:
            message = 'Unhandled exception in event loop'

        exception = context.get('exception')
        if exception is not None:
            exc_info = (type(exception), exception, exception.__traceback__)
        else:
            exc_info = False

        aio_logger.error(message, exc_info=exc_info)

    def set_exception_handler(self, handler):
        if handler is not None and not callable(handler):
            raise TypeError('A callable object or None is expected, '
                            'got {!r}'.format(handler))
        self._exception_handler = handler

    def call_exception_handler(self, context):
        if self._exception_handler is None:
            try:
                self.default_exception_handler(context)
            except Exception:
                # Second protection layer for unexpected errors
                # in the default implementation, as well as for subclassed
                # event loops with overloaded "default_exception_handler".
                aio_logger.error('Exception in default exception handler',
                                 exc_info=True)
        else:
            try:
                self._exception_handler(self, context)
            except Exception as exc:
                # Exception in the user set custom exception handler.
                try:
                    # Let's try default handler.
                    self.default_exception_handler({
                        'message': 'Unhandled error in exception handler',
                        'exception': exc,
                        'context': context,
                    })
                except Exception:
                    # Guard 'default_exception_handler' in case it is
                    # overloaded.
                    aio_logger.error('Exception in default exception handler '
                                     'while handling an unexpected error '
                                     'in custom exception handler',
                                     exc_info=True)

    def add_reader(self, fd, callback, *args):
        cdef:
            UVPoll poll

        self._check_closed()

        try:
            poll = <UVPoll>(self._polls[fd])
        except KeyError:
            poll = UVPoll.new(self, fd)
            self._polls[fd] = poll

        if not args:
            args = None

        poll.start_reading(Handle(self, callback, args))

    def remove_reader(self, fd):
        cdef:
            UVPoll poll

        if self._closed == 1:
            return False

        try:
            poll = <UVPoll>(self._polls[fd])
        except KeyError:
            return False

        result = poll.stop_reading()
        if not poll.is_active():
            self._polls_gc[fd] = poll
        return result

    def add_writer(self, fd, callback, *args):
        cdef:
            UVPoll poll

        self._check_closed()

        try:
            poll = <UVPoll>(self._polls[fd])
        except KeyError:
            poll = UVPoll.new(self, fd)
            self._polls[fd] = poll

        if not args:
            args = None

        poll.start_writing(Handle(self, callback, args))

    def remove_writer(self, fd):
        cdef:
            UVPoll poll

        if self._closed == 1:
            return False

        try:
            poll = <UVPoll>(self._polls[fd])
        except KeyError:
            return False

        result = poll.stop_writing()
        if not poll.is_active():
            self._polls_gc[fd] = poll
        return result

    def sock_recv(self, sock, n):
        if self._debug and sock.gettimeout() != 0:
            raise ValueError("the socket must be non-blocking")
        fut = aio_Future(loop=self)
        self._sock_recv(fut, False, sock, n)
        return fut

    def sock_sendall(self, sock, data):
        if self._debug and sock.gettimeout() != 0:
            raise ValueError("the socket must be non-blocking")
        fut = aio_Future(loop=self)
        if data:
            self._sock_sendall(fut, False, sock, data)
        else:
            fut.set_result(None)
        return fut

    def sock_accept(self, sock):
        if self._debug and sock.gettimeout() != 0:
            raise ValueError("the socket must be non-blocking")
        fut = aio_Future(loop=self)
        self._sock_accept(fut, False, sock)
        return fut

    def sock_connect(self, sock, address):
        if self._debug and sock.gettimeout() != 0:
            raise ValueError("the socket must be non-blocking")
        fut = aio_Future(loop=self)
        try:
            if self._debug:
                aio__check_resolved_address(sock, address)
        except ValueError as err:
            fut.set_exception(err)
        else:
            self._sock_connect(fut, sock, address)
        return fut

    def run_in_executor(self, executor, func, *args):
        if aio_iscoroutine(func) or aio_iscoroutinefunction(func):
            raise TypeError("coroutines cannot be used with run_in_executor()")

        self._check_closed()

        if executor is None:
            executor = self._default_executor
            if executor is None:
                executor = cc_ThreadPoolExecutor(MAX_THREADPOOL_WORKERS)
                self._default_executor = executor

        return aio_wrap_future(executor.submit(func, *args), loop=self)

    def set_default_executor(self, executor):
        self._default_executor = executor


cdef void __loop_alloc_buffer(uv.uv_handle_t* uvhandle,
                              size_t suggested_size,
                              uv.uv_buf_t* buf) with gil:
    cdef:
        Loop loop = (<UVHandle>uvhandle.data)._loop

    if loop._recv_buffer_in_use == 1:
        buf.len = 0
        exc = RuntimeError('concurrent allocations')
        loop._handle_exception(exc)
        return

    loop._recv_buffer_in_use = 1
    buf.base = loop._recv_buffer
    buf.len = sizeof(loop._recv_buffer)


cdef inline void __loop_free_buffer(Loop loop):
    loop._recv_buffer_in_use = 0


include "cbhandles.pyx"

include "handles/handle.pyx"
include "handles/async_.pyx"
include "handles/idle.pyx"
include "handles/timer.pyx"
include "handles/signal.pyx"
include "handles/poll.pyx"
include "handles/stream.pyx"
include "handles/tcp.pyx"

include "request.pyx"
include "dns.pyx"

include "server.pyx"

include "os_signal.pyx"


# Install PyMem* memory allocators
cdef bint __mem_installed = 0
cdef __install_pymem():
    global __mem_installed
    if __mem_installed:
        return
    __mem_installed = 1

    cdef int err
    err = uv.uv_replace_allocator(<uv.uv_malloc_func>PyMem_Malloc,
                                  <uv.uv_realloc_func>PyMem_Realloc,
                                  <uv.uv_calloc_func>PyMem_Calloc,
                                  <uv.uv_free_func>PyMem_Free)
    if err < 0:
        raise convert_error(err)
