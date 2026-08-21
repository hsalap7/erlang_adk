%% @doc Capability-negotiated, credit/ack artifact transfer facade.
%%
%% A stream handle is bound to the process that opened it. Upload chunks are
%% synchronous and return an acknowledgement plus the next credit grant.
%% Downloads require an explicit credit grant and an acknowledgement for every
%% delivered chunk; at most one chunk is in flight.
-module(adk_artifact_stream).

-export([
    open_upload/5,
    open_download/5,
    send_chunk/3,
    send_chunk/4,
    finish_upload/1,
    finish_upload/2,
    credit/3,
    ack/2,
    cancel/2,
    recv/2
]).

-type stream() :: {adk_artifact_stream, pid(), reference()}.
-type event() ::
    {chunk, pos_integer(), non_neg_integer(), binary()}
    | {done, map()}
    | {error, timeout | cancelled | unavailable | term()}.

-export_type([stream/0, event/0]).

-define(DEFAULT_CALL_TIMEOUT_MS, 5000).

-spec open_upload({module(), term()}, adk_artifact_service:scope(), binary(),
                  map(), map()) ->
    {ok, stream(), map()} | {error, term()}.
open_upload({Module, Handle}, Scope, Name, PutOptions, TransferOptions)
  when is_atom(Module) ->
    negotiated_call(Module, Handle, upload,
                    fun() ->
                        Module:start_upload(Handle, Scope, Name, PutOptions,
                                            TransferOptions)
                    end);
open_upload(_Service, _Scope, _Name, _PutOptions, _TransferOptions) ->
    {error, invalid_service}.

-spec open_download({module(), term()}, adk_artifact_service:scope(), binary(),
                    adk_artifact_service:selector(), map()) ->
    {ok, stream(), map()} | {error, term()}.
open_download({Module, Handle}, Scope, Name, Selector, TransferOptions)
  when is_atom(Module) ->
    negotiated_call(Module, Handle, download,
                    fun() ->
                        Module:start_download(Handle, Scope, Name, Selector,
                                              TransferOptions)
                    end);
open_download(_Service, _Scope, _Name, _Selector, _TransferOptions) ->
    {error, invalid_service}.

-spec send_chunk(stream(), pos_integer(), binary()) ->
    {ok, map()} | {error, term()}.
send_chunk(Stream, Sequence, Chunk) ->
    send_chunk(Stream, Sequence, Chunk, ?DEFAULT_CALL_TIMEOUT_MS).

-spec send_chunk(stream(), pos_integer(), binary(), pos_integer()) ->
    {ok, map()} | {error, term()}.
send_chunk(Stream, Sequence, Chunk, Timeout) ->
    stream_call(Stream, {upload_chunk, Sequence, Chunk}, Timeout).

-spec finish_upload(stream()) -> {ok, map()} | {error, term()}.
finish_upload(Stream) ->
    finish_upload(Stream, ?DEFAULT_CALL_TIMEOUT_MS).

-spec finish_upload(stream(), pos_integer()) ->
    {ok, map()} | {error, term()}.
finish_upload(Stream, Timeout) ->
    stream_call(Stream, finish_upload, Timeout).

-spec credit(stream(), pos_integer(), pos_integer()) ->
    ok | {error, term()}.
credit(Stream, Messages, Bytes) ->
    stream_call(Stream, {credit, Messages, Bytes}, ?DEFAULT_CALL_TIMEOUT_MS).

-spec ack(stream(), pos_integer()) -> ok | {error, term()}.
ack(Stream, Sequence) ->
    stream_call(Stream, {ack, Sequence}, ?DEFAULT_CALL_TIMEOUT_MS).

-spec cancel(stream(), term()) -> ok | {error, term()}.
cancel(Stream, Reason) ->
    stream_call(Stream, {cancel, Reason}, ?DEFAULT_CALL_TIMEOUT_MS).

-spec recv(stream(), timeout()) -> {ok, event()} | {error, timeout}.
recv({adk_artifact_stream, _Pid, Ref}, Timeout)
  when is_reference(Ref),
       (Timeout =:= infinity orelse
        (is_integer(Timeout) andalso Timeout >= 0)) ->
    receive
        {adk_artifact_stream, Ref, Event} -> {ok, Event}
    after Timeout ->
        {error, timeout}
    end;
recv(_Stream, _Timeout) ->
    {error, invalid_stream}.

negotiated_call(Module, Handle, Direction, Fun) ->
    try Module:capabilities(Handle) of
        {ok, #{transfer := Transfer}} when is_map(Transfer) ->
            case maps:get(Direction, Transfer, false) andalso
                 callback_exported(Module, Direction) of
                true -> safe_invoke(Fun);
                false -> {error, unsupported_transfer}
            end;
        _ -> {error, unsupported_transfer}
    catch
        _:_ -> {error, unavailable}
    end.

callback_exported(Module, upload) ->
    erlang:function_exported(Module, start_upload, 5);
callback_exported(Module, download) ->
    erlang:function_exported(Module, start_download, 5).

safe_invoke(Fun) ->
    try Fun() of
        Result -> Result
    catch
        _:_ -> {error, unavailable}
    end.

stream_call({adk_artifact_stream, Pid, Ref}, Request, Timeout)
  when is_pid(Pid), is_reference(Ref), is_integer(Timeout), Timeout > 0 ->
    try gen_server:call(Pid, {stream, Ref, Request}, Timeout) of
        Reply -> Reply
    catch
        exit:{timeout, _} -> {error, timeout};
        exit:{noproc, _} -> {error, unavailable};
        exit:_ -> {error, unavailable}
    end;
stream_call(_Stream, _Request, _Timeout) ->
    {error, invalid_stream}.
