-module(adk_live_fake_transport).
-behaviour(adk_live_transport).
-behaviour(gen_server).

-export([open/2, send/2, close/2,
         inject/2, set_busy/2, set_auto_ack/2, ack_sent/1,
         writable/1, disconnect/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

open(Owner, Options) when is_pid(Owner), is_map(Options) ->
    case maps:get(test_pid, Options, undefined) of
        TestPid when is_pid(TestPid) ->
            gen_server:start_link(?MODULE, {Owner, TestPid, Options}, []);
        _ -> {error, invalid_fake_transport_options}
    end.

send(Handle, Frame) when is_pid(Handle), is_binary(Frame) ->
    gen_server:call(Handle, {send, Frame});
send(_Handle, _Frame) ->
    {error, invalid_frame}.

close(Handle, Reason) when is_pid(Handle) ->
    try gen_server:call(Handle, {close, Reason}) of
        ok -> ok
    catch
        exit:_ -> ok
    end;
close(_Handle, _Reason) -> ok.

inject(Handle, Map) when is_pid(Handle), is_map(Map) ->
    gen_server:cast(Handle, {inject, jsx:encode(Map)});
inject(Handle, Frame) when is_pid(Handle), is_binary(Frame) ->
    gen_server:cast(Handle, {inject, Frame}).

set_busy(Handle, Busy) when is_pid(Handle), is_boolean(Busy) ->
    gen_server:call(Handle, {set_busy, Busy}).

set_auto_ack(Handle, AutoAck)
  when is_pid(Handle), is_boolean(AutoAck) ->
    gen_server:call(Handle, {set_auto_ack, AutoAck}).

ack_sent(Handle) when is_pid(Handle) ->
    gen_server:call(Handle, ack_sent).

writable(Handle) when is_pid(Handle) ->
    gen_server:call(Handle, writable).

disconnect(Handle, Reason) when is_pid(Handle) ->
    gen_server:call(Handle, {disconnect, Reason}).

init({Owner, TestPid, Options}) ->
    self() ! connected,
    TestPid ! {adk_live_fake_transport, opened, self()},
    {ok, #{owner => Owner,
           test_pid => TestPid,
           busy => maps:get(busy, Options, false),
           auto_ack => maps:get(auto_ack, Options, true),
           pending => undefined,
           sent => 0}}.

handle_call({send, _Frame}, _From, #{busy := true} = State) ->
    {reply, {error, busy}, State};
handle_call({send, _Frame}, _From, #{pending := Pending} = State)
  when Pending =/= undefined ->
    {reply, {error, busy}, State};
handle_call({send, Frame}, _From, State0) ->
    SendRef = make_ref(),
    TestPid = maps:get(test_pid, State0),
    TestPid ! {adk_live_fake_transport, sent, self(), Frame},
    State = State0#{pending => SendRef,
                    sent => maps:get(sent, State0) + 1},
    case maps:get(auto_ack, State) of
        true -> {reply, {ok, SendRef}, acknowledge_send(State)};
        false -> {reply, {ok, SendRef}, State}
    end;
handle_call({set_busy, Busy}, _From, State) ->
    {reply, ok, State#{busy => Busy}};
handle_call({set_auto_ack, AutoAck}, _From, State) ->
    {reply, ok, State#{auto_ack => AutoAck}};
handle_call(ack_sent, _From, #{pending := undefined} = State) ->
    {reply, {error, no_pending_send}, State};
handle_call(ack_sent, _From, State) ->
    {reply, ok, acknowledge_send(State)};
handle_call(writable, _From, State) ->
    Owner = maps:get(owner, State),
    Owner ! {adk_live_transport, self(), writable},
    {reply, ok, State#{busy => false}};
handle_call({close, Reason}, _From, State) ->
    maps:get(test_pid, State) !
        {adk_live_fake_transport, closed, self(), Reason},
    {stop, normal, ok, State};
handle_call({disconnect, Reason}, _From, State) ->
    Owner = maps:get(owner, State),
    Owner ! {adk_live_transport, self(), {closed, Reason}},
    maps:get(test_pid, State) !
        {adk_live_fake_transport, disconnected, self(), Reason},
    {stop, normal, ok, State};
handle_call(_Request, _From, State) ->
    {reply, {error, bad_request}, State}.

handle_cast({inject, Frame}, State) ->
    maps:get(owner, State) !
        {adk_live_transport, self(), {frame, Frame}},
    {noreply, State};
handle_cast(_Message, State) ->
    {noreply, State}.

handle_info(connected, State) ->
    maps:get(owner, State) !
        {adk_live_transport, self(), connected},
    {noreply, State};
handle_info(_Message, State) ->
    {noreply, State}.

terminate(_Reason, _State) -> ok.
code_change(_OldVsn, State, _Extra) -> {ok, State}.

acknowledge_send(#{owner := Owner, pending := SendRef} = State) ->
    Owner ! {adk_live_transport, self(), {sent, SendRef}},
    Owner ! {adk_live_transport, self(), writable},
    State#{pending => undefined}.
