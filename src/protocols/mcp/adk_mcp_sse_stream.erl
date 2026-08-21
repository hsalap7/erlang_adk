%% @doc Incremental, credit-driven SSE decoder for MCP Streamable HTTP.
%%
%% `feed/3' never delivers more complete events than the owner has granted.
%% Complete-but-undelivered input remains bounded inside the worker and the
%% producer receives `paused', making backpressure explicit.  The worker is
%% not linked to the owner, but monitors it and terminates immediately when the
%% owner dies.  `decode/2' exposes the same parser as a pure helper for a
%% transport process that already owns its receive loop.
-module(adk_mcp_sse_stream).
-behaviour(gen_server).

-export([start/2, start_link/2, credit/2, feed/3, cancel/1,
         new/1, grant/2, decode/3, finish/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3, format_status/1]).

-define(DEFAULT_MAX_BYTES, 4194304).
-define(DEFAULT_MAX_EVENT_BYTES, 1048576).
-define(DEFAULT_MAX_EVENTS, 1024).
-define(MAX_CREDIT, 65536).
-define(CALL_TIMEOUT, 5000).

-spec start(pid(), map()) -> gen_server:start_ret().
start(Owner, Options) -> gen_server:start(?MODULE, {Owner, Options}, []).

-spec start_link(pid(), map()) -> gen_server:start_ret().
start_link(Owner, Options) ->
    gen_server:start_link(?MODULE, {Owner, Options}, []).

-spec credit(pid(), pos_integer()) -> ok | {error, term()}.
credit(Stream, Amount) -> safe_call(Stream, {credit, Amount}).

-spec feed(pid(), binary(), boolean()) ->
    {ok, non_neg_integer(), ready | paused | done} | {error, term()}.
feed(Stream, Chunk, Fin) -> safe_call(Stream, {feed, Chunk, Fin}).

-spec cancel(pid()) -> ok.
cancel(Stream) ->
    _ = catch gen_server:stop(Stream, normal, ?CALL_TIMEOUT),
    ok.

%% Pure parser API.  State values are deliberately validated on every entry;
%% callers cannot use a fabricated map to bypass configured limits.
-spec new(map()) -> {ok, map()} | {error, term()}.
new(Options) when is_map(Options) ->
    MaxBytes = maps:get(max_bytes, Options, ?DEFAULT_MAX_BYTES),
    MaxEventBytes = maps:get(max_event_bytes, Options,
                             ?DEFAULT_MAX_EVENT_BYTES),
    MaxEvents = maps:get(max_events, Options, ?DEFAULT_MAX_EVENTS),
    case valid_positive(MaxBytes, 67108864) andalso
         valid_positive(MaxEventBytes, MaxBytes) andalso
         valid_positive(MaxEvents, 65536) of
        true ->
            {ok, #{tag => ?MODULE, buffer => <<>>, bytes => 0,
                   event_count => 0, credit => 0, finished => false,
                   input_finished => false, pending_cr => false,
                   max_bytes => MaxBytes, max_event_bytes => MaxEventBytes,
                   max_events => MaxEvents}};
        false -> {error, invalid_mcp_sse_options}
    end;
new(_Options) -> {error, invalid_mcp_sse_options}.

-spec grant(map(), pos_integer()) -> {ok, map()} | {error, term()}.
grant(State, Amount) when is_integer(Amount), Amount > 0,
                          Amount =< ?MAX_CREDIT ->
    case valid_state(State) of
        true ->
            Current = maps:get(credit, State),
            {ok, State#{credit => erlang:min(?MAX_CREDIT,
                                             Current + Amount)}};
        false -> {error, invalid_mcp_sse_state}
    end;
grant(_State, _Amount) -> {error, invalid_mcp_sse_credit}.

-spec decode(map(), binary(), boolean()) ->
    {ok, [map()], map(), ready | paused | done} | {error, term()}.
decode(State0, Chunk0, Fin)
  when is_binary(Chunk0), is_boolean(Fin) ->
    case valid_state(State0) andalso not maps:get(finished, State0) of
        false -> {error, invalid_mcp_sse_state};
        true ->
            {Chunk, PendingCr} = normalize_chunk(
                                   Chunk0, maps:get(pending_cr, State0), Fin),
            Bytes = maps:get(bytes, State0) + byte_size(Chunk0),
            Buffer = <<(maps:get(buffer, State0))/binary, Chunk/binary>>,
            case Bytes =< maps:get(max_bytes, State0) andalso
                 byte_size(Buffer) =< maps:get(max_bytes, State0) of
                false -> {error, mcp_sse_limit_exceeded};
                true ->
                    InputFinished = maps:get(input_finished, State0) orelse Fin,
                    State1 = State0#{buffer => Buffer, bytes => Bytes,
                                     pending_cr => PendingCr,
                                     input_finished => InputFinished},
                    parse_available(State1, InputFinished, [])
            end
    end;
decode(_State, _Chunk, _Fin) -> {error, invalid_mcp_sse_feed}.

-spec finish(map()) -> {ok, [map()], map(), done | paused} | {error, term()}.
finish(State) -> decode(State, <<>>, true).

init({Owner, Options}) when is_pid(Owner), is_map(Options) ->
    case new(Options) of
        {ok, Parser} ->
            Monitor = erlang:monitor(process, Owner),
            {ok, #{owner => Owner, owner_monitor => Monitor,
                   parser => Parser}};
        {error, Reason} -> {stop, Reason}
    end;
init(_) -> {stop, invalid_mcp_sse_owner}.

handle_call({credit, Amount}, _From, State) ->
    Parser0 = maps:get(parser, State),
    case grant(Parser0, Amount) of
        {ok, Parser1} ->
            case decode(Parser1, <<>>, false) of
                {ok, Events, Parser, Status} ->
                    deliver(Events, State),
                    Updated = State#{parser => Parser, status => Status},
                    case Status of
                        done -> {stop, normal, ok, Updated};
                        _ -> {reply, ok, Updated}
                    end;
                {error, Reason} -> {stop, Reason, {error, Reason}, State}
            end;
        {error, _} = Error -> {reply, Error, State}
    end;
handle_call({feed, Chunk, Fin}, _From, State) ->
    case decode(maps:get(parser, State), Chunk, Fin) of
        {ok, Events, Parser, Status} ->
            deliver(Events, State),
            Reply = {ok, length(Events), Status},
            Updated = State#{parser => Parser, status => Status},
            case Status of
                done -> {stop, normal, Reply, Updated};
                _ -> {reply, Reply, Updated}
            end;
        {error, Reason} -> {stop, Reason, {error, Reason}, State}
    end;
handle_call(_Request, _From, State) ->
    {reply, {error, invalid_mcp_sse_request}, State}.

handle_cast(_Message, State) -> {noreply, State}.

handle_info({'DOWN', Monitor, process, Owner, _Reason},
            #{owner := Owner, owner_monitor := Monitor} = State) ->
    {stop, normal, State};
handle_info(_Message, State) -> {noreply, State}.

terminate(_Reason, State) ->
    case maps:find(owner_monitor, State) of
        {ok, Monitor} -> erlang:demonitor(Monitor, [flush]);
        error -> ok
    end,
    ok.

code_change(_OldVersion, State, _Extra) -> {ok, State}.

format_status(Status) when is_map(Status) ->
    maps:map(
      fun(state, State) when is_map(State) ->
              Parser = maps:get(parser, State, #{}),
              #{owner => maps:get(owner, State, undefined),
                bytes => maps:get(bytes, Parser, 0),
                event_count => maps:get(event_count, Parser, 0),
                buffered_bytes => byte_size(maps:get(buffer, Parser, <<>>)),
                credit => maps:get(credit, Parser, 0)};
         (message, _Message) -> redacted;
         (log, _Log) -> [];
         (_Key, Value) -> Value
      end, Status);
format_status(Status) -> Status.

parse_available(State = #{credit := 0}, Fin, Acc) ->
    finish_status(State, Fin, Acc, paused);
parse_available(State0, Fin, Acc) ->
    Buffer = maps:get(buffer, State0),
    case split_event(Buffer, Fin) of
        more -> finish_status(State0, Fin, Acc, ready);
        {ok, EventBytes, Rest} ->
            Count = maps:get(event_count, State0) + 1,
            case Count =< maps:get(max_events, State0) andalso
                 byte_size(EventBytes) =< maps:get(max_event_bytes, State0) of
                false -> {error, mcp_sse_limit_exceeded};
                true ->
                    case parse_event(EventBytes) of
                        ignore ->
                            parse_available(State0#{buffer => Rest}, Fin, Acc);
                        {ok, Event} ->
                            State = State0#{buffer => Rest,
                                            event_count => Count,
                                            credit => maps:get(credit,
                                                               State0) - 1},
                            parse_available(State, Fin, [Event | Acc]);
                        {error, _} = Error -> Error
                    end
            end
    end.

finish_status(State, true, Acc, Default) ->
    case maps:get(buffer, State) of
        <<>> -> {ok, lists:reverse(Acc), State#{finished => true}, done};
        Buffer ->
            case only_comments_or_space(Buffer) of
                true -> {ok, lists:reverse(Acc),
                         State#{buffer => <<>>, finished => true}, done};
                false when Default =:= paused ->
                    {ok, lists:reverse(Acc), State, paused};
                false -> {error, truncated_mcp_sse_event}
            end
    end;
finish_status(State, false, Acc, Default) ->
    Status = case {Default, maps:get(buffer, State)} of
        {paused, _} -> paused;
        {_, <<>>} -> ready;
        _ -> ready
    end,
    {ok, lists:reverse(Acc), State, Status}.

split_event(Buffer, _Fin) ->
    case binary:match(Buffer, <<"\n\n">>) of
        {Pos, 2} ->
            {ok, binary:part(Buffer, 0, Pos),
             binary:part(Buffer, Pos + 2, byte_size(Buffer) - Pos - 2)};
        nomatch -> more
    end.

parse_event(<<>>) -> ignore;
parse_event(Bytes) ->
    Lines = binary:split(Bytes, <<"\n">>, [global]),
    parse_lines(Lines, #{data_lines => []}).

parse_lines([], #{data_lines := []}) -> ignore;
parse_lines([], #{data_lines := DataLines} = Event0) ->
    Data = iolist_to_binary(lists:join(<<"\n">>, lists:reverse(DataLines))),
    {ok, (maps:remove(data_lines, Event0))#{data => Data}};
parse_lines([<<":", _/binary>> | Rest], Event) -> parse_lines(Rest, Event);
parse_lines([Line | Rest], Event0) ->
    {Field, Value} = split_field(Line),
    case Field of
        <<"data">> ->
            Lines = maps:get(data_lines, Event0),
            parse_lines(Rest, Event0#{data_lines => [Value | Lines]});
        <<"event">> -> parse_lines(Rest, Event0#{event => Value});
        <<"id">> ->
            case binary:match(Value, <<0>>) of
                nomatch -> parse_lines(Rest, Event0#{id => Value});
                _ -> {error, invalid_mcp_sse_id}
            end;
        <<"retry">> ->
            case parse_retry(Value) of
                {ok, Retry} -> parse_lines(Rest, Event0#{retry => Retry});
                error -> parse_lines(Rest, Event0)
            end;
        _ -> parse_lines(Rest, Event0)
    end.

split_field(Line) ->
    case binary:match(Line, <<":">>) of
        {Pos, 1} ->
            Value0 = binary:part(Line, Pos + 1,
                                 byte_size(Line) - Pos - 1),
            Value = case Value0 of <<" ", Rest/binary>> -> Rest;
                                   _ -> Value0 end,
            {binary:part(Line, 0, Pos), Value};
        nomatch -> {Line, <<>>}
    end.

parse_retry(Value) ->
    try binary_to_integer(Value) of
        Retry when Retry >= 0, Retry =< 3600000 -> {ok, Retry};
        _ -> error
    catch _:_ -> error
    end.

deliver(Events, #{owner := Owner}) ->
    lists:foreach(fun(Event) -> Owner ! {mcp_sse_event, self(), Event} end,
                  Events).

valid_state(#{tag := ?MODULE, buffer := Buffer, bytes := Bytes,
              event_count := Count, credit := Credit, finished := Finished,
              input_finished := InputFinished, pending_cr := PendingCr,
              max_bytes := MaxBytes, max_event_bytes := MaxEventBytes,
              max_events := MaxEvents}) ->
    is_binary(Buffer) andalso is_integer(Bytes) andalso Bytes >= 0 andalso
    is_integer(Count) andalso Count >= 0 andalso
    is_integer(Credit) andalso Credit >= 0 andalso Credit =< ?MAX_CREDIT andalso
    is_boolean(Finished) andalso is_boolean(InputFinished) andalso
    is_boolean(PendingCr) andalso
    valid_positive(MaxBytes, 67108864) andalso
    valid_positive(MaxEventBytes, MaxBytes) andalso
    valid_positive(MaxEvents, 65536) andalso
    byte_size(Buffer) =< MaxBytes andalso Bytes =< MaxBytes andalso
    Count =< MaxEvents;
valid_state(_) -> false.

only_comments_or_space(Buffer) ->
    lists:all(
      fun(Line) ->
              Trimmed = string:trim(binary_to_list(Line)),
              Trimmed =:= [] orelse hd(Trimmed) =:= $:
      end, binary:split(Buffer, <<"\n">>, [global])).

normalize_chunk(Chunk, PendingCr, Fin) ->
    Combined0 = case PendingCr of
        true -> <<"\r", Chunk/binary>>;
        false -> Chunk
    end,
    {Combined, NextPendingCr} = case {Fin, Combined0} of
        {false, <<>>} -> {<<>>, false};
        {false, _} ->
            Last = byte_size(Combined0) - 1,
            case binary:at(Combined0, Last) of
                $\r -> {binary:part(Combined0, 0, Last), true};
                _ -> {Combined0, false}
            end;
        {true, _} -> {Combined0, false}
    end,
    {normalize_newlines(Combined), NextPendingCr}.

normalize_newlines(Binary) ->
    binary:replace(binary:replace(Binary, <<"\r\n">>, <<"\n">>, [global]),
                   <<"\r">>, <<"\n">>, [global]).

valid_positive(Value, Ceiling) ->
    is_integer(Value) andalso Value > 0 andalso Value =< Ceiling.

safe_call(Stream, Request) ->
    try gen_server:call(Stream, Request, ?CALL_TIMEOUT) of
        Reply -> Reply
    catch
        exit:{noproc, _} -> {error, mcp_sse_stream_closed};
        exit:{timeout, _} -> {error, mcp_sse_stream_timeout};
        exit:_ -> {error, mcp_sse_stream_closed}
    end.
