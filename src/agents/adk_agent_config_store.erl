%% @doc Private hand-off store for supervised agent start arguments.
%%
%% Dynamic-supervisor child MFAs are included in supervisor reports. Keeping
%% the full provider configuration there would therefore disclose explicit
%% credentials whenever an agent terminates. The supervisor retains only a
%% random opaque reference; this process holds the corresponding start data.
-module(adk_agent_config_store).
-behaviour(gen_server).

-export([start_link/0, child_spec/1,
         put/3, get_for_start/1, claim/2, delete/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3, format_status/1]).

-define(DEFAULT_RETENTION_MS, 60000).

-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec child_spec(term()) -> supervisor:child_spec().
child_spec(_Options) ->
    #{id => ?MODULE,
      start => {?MODULE, start_link, []},
      restart => permanent,
      shutdown => 5000,
      type => worker,
      modules => [?MODULE]}.

-spec put(string() | binary(), map(), list()) ->
    {ok, binary()} | {error, term()}.
put(Name, Config, Tools) when is_map(Config), is_list(Tools) ->
    gen_server:call(?MODULE, {put, Name, Config, Tools}, 5000).

%% This operation is deliberately restricted to the registered agent
%% supervisor. It is called from the child start MFA in that supervisor's
%% process and never exposed through the public ADK API.
-spec get_for_start(binary()) ->
    {ok, string() | binary(), map(), list()} | {error, term()}.
get_for_start(Ref) when is_binary(Ref) ->
    gen_server:call(?MODULE, {get_for_start, Ref}, 5000).

-spec claim(binary(), pid()) -> ok | {error, term()}.
claim(Ref, AgentPid) when is_binary(Ref), is_pid(AgentPid) ->
    gen_server:call(?MODULE, {claim, Ref, AgentPid}, 5000).

-spec delete(binary()) -> ok.
delete(Ref) when is_binary(Ref) ->
    gen_server:call(?MODULE, {delete, Ref}, 5000).

init([]) ->
    {ok, #{entries => #{}, monitors => #{}}}.

handle_call({put, Name, Config, Tools}, _From, State0) ->
    Ref = unique_ref(maps:get(entries, State0)),
    Entry = #{name => Name,
              config => Config,
              tools => Tools,
              agent_pid => undefined,
              monitor => undefined,
              cleanup_timer => undefined},
    Entries = (maps:get(entries, State0))#{Ref => Entry},
    {reply, {ok, Ref}, State0#{entries => Entries}};
handle_call({get_for_start, Ref}, {Caller, _Tag}, State) ->
    case Caller =:= whereis(adk_agent_sup) of
        false ->
            {reply, {error, unauthorized_agent_start}, State};
        true ->
            case maps:find(Ref, maps:get(entries, State)) of
                {ok, Entry} ->
                    {reply,
                     {ok, maps:get(name, Entry), maps:get(config, Entry),
                      maps:get(tools, Entry)},
                     State};
                error ->
                    {reply, {error, unknown_agent_config_ref}, State}
            end
    end;
handle_call({claim, Ref, AgentPid}, _From, State0) ->
    case maps:find(Ref, maps:get(entries, State0)) of
        error ->
            {reply, {error, unknown_agent_config_ref}, State0};
        {ok, Entry0} ->
            State1 = detach_entry_monitor(Entry0, State0),
            Entry1 = cancel_cleanup(Entry0),
            Monitor = erlang:monitor(process, AgentPid),
            Entry2 = Entry1#{agent_pid => AgentPid,
                             monitor => Monitor,
                             cleanup_timer => undefined},
            Entries = (maps:get(entries, State1))#{Ref => Entry2},
            Monitors = (maps:get(monitors, State1))#{Monitor => Ref},
            {reply, ok, State1#{entries => Entries,
                               monitors => Monitors}}
    end;
handle_call({delete, Ref}, _From, State0) ->
    {reply, ok, delete_entry(Ref, State0)};
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_request}, State}.

handle_cast(_Message, State) ->
    {noreply, State}.

handle_info({'DOWN', Monitor, process, _AgentPid, Reason}, State0) ->
    case maps:take(Monitor, maps:get(monitors, State0)) of
        error ->
            {noreply, State0};
        {Ref, Monitors} ->
            State1 = State0#{monitors => Monitors},
            case maps:find(Ref, maps:get(entries, State1)) of
                {ok, #{monitor := Monitor} = Entry0} ->
                    handle_agent_down(Ref, Reason, Entry0, State1);
                _ ->
                    {noreply, State1}
            end
    end;
handle_info({expire_agent_config, Ref, Token}, State0) ->
    case maps:find(Ref, maps:get(entries, State0)) of
        {ok, #{cleanup_timer := {Token, _TimerRef},
               agent_pid := undefined}} ->
            {noreply, delete_entry(Ref, State0)};
        _ ->
            {noreply, State0}
    end;
handle_info(_Message, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    maps:foreach(
      fun(_Ref, Entry) ->
          _ = cancel_cleanup(Entry),
          demonitor_ref(maps:get(monitor, Entry, undefined))
      end, maps:get(entries, State, #{})),
    ok.

code_change(_OldVersion, State, _Extra) ->
    {ok, State}.

%% Configs, tools, timer messages, and termination reasons can all contain
%% credentials or user content. Only an aggregate count is observable.
format_status(Status) ->
    maps:map(
      fun(state, State) when is_map(State) ->
              #{stored_agent_configs =>
                    map_size(maps:get(entries, State, #{}))};
         (message, _Message) -> adk_secret_redactor:marker();
         (log, _Log) -> [];
         (reason, _Reason) -> adk_secret_redactor:marker();
         (_Key, _Value) -> adk_secret_redactor:marker()
      end, Status).

handle_agent_down(Ref, normal, _Entry, State) ->
    {noreply, delete_entry(Ref, State)};
handle_agent_down(Ref, shutdown, _Entry, State) ->
    {noreply, delete_entry(Ref, State)};
handle_agent_down(Ref, {shutdown, _}, _Entry, State) ->
    {noreply, delete_entry(Ref, State)};
handle_agent_down(Ref, _AbnormalReason, Entry0, State0) ->
    %% A transient child restarts immediately with the same opaque reference.
    %% Retain it briefly for that restart, then expire it if the supervisor has
    %% exceeded its restart intensity or has itself disappeared.
    Token = make_ref(),
    Timer = erlang:send_after(retention_ms(), self(),
                              {expire_agent_config, Ref, Token}),
    Entry = Entry0#{agent_pid => undefined,
                    monitor => undefined,
                    cleanup_timer => {Token, Timer}},
    Entries = (maps:get(entries, State0))#{Ref => Entry},
    {noreply, State0#{entries => Entries}}.

retention_ms() ->
    case application:get_env(erlang_adk, agent_config_retention_ms,
                             ?DEFAULT_RETENTION_MS) of
        Value when is_integer(Value), Value > 0 -> Value;
        _Invalid -> ?DEFAULT_RETENTION_MS
    end.

unique_ref(Entries) ->
    Ref = crypto:strong_rand_bytes(32),
    case maps:is_key(Ref, Entries) of
        true -> unique_ref(Entries);
        false -> Ref
    end.

delete_entry(Ref, State0) ->
    case maps:take(Ref, maps:get(entries, State0)) of
        error -> State0;
        {Entry, Entries} ->
            _ = cancel_cleanup(Entry),
            Monitor = maps:get(monitor, Entry, undefined),
            demonitor_ref(Monitor),
            Monitors = case Monitor of
                undefined -> maps:get(monitors, State0);
                _ -> maps:remove(Monitor, maps:get(monitors, State0))
            end,
            State0#{entries => Entries, monitors => Monitors}
    end.

detach_entry_monitor(Entry, State0) ->
    case maps:get(monitor, Entry, undefined) of
        undefined -> State0;
        Monitor ->
            demonitor_ref(Monitor),
            State0#{monitors => maps:remove(
                                  Monitor, maps:get(monitors, State0))}
    end.

cancel_cleanup(Entry) ->
    case maps:get(cleanup_timer, Entry, undefined) of
        {_Token, TimerRef} ->
            _ = erlang:cancel_timer(TimerRef),
            Entry#{cleanup_timer => undefined};
        undefined -> Entry
    end.

demonitor_ref(undefined) -> ok;
demonitor_ref(Monitor) ->
    _ = erlang:demonitor(Monitor, [flush]),
    ok.
