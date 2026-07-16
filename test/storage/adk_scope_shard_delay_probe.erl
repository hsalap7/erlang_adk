%% Test-only adapter implementing both complete sharded callback sets.
-module(adk_scope_shard_delay_probe).
-behaviour(gen_server).

-export([start_link/1, stop/1, capabilities/1,
         put/5, put/6, get/4, get/5, list/2,
         list_names/3, list_versions/4, delete/4, delete/5,
         add_entry/4, add_entry/5, add_events/5, add_events/6,
         add_session_to_memory/5, search/4, search/5,
         delete_entry/3, delete_entry/4,
         delete_session/3, delete_session/4,
         delete_user/2, delete_user/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {owner, mode, barrier = false}).

start_link(Config) -> gen_server:start_link(?MODULE, Config, []).
stop(Pid) -> gen_server:stop(Pid).
capabilities(Pid) -> gen_server:call(Pid, capabilities, 5000).

put(Pid, Scope, Name, Data, Options) ->
    put(Pid, Scope, Name, Data, Options, #{}).
put(Pid, Scope, _Name, _Data, _Options, CallOptions) ->
    gen_server:call(Pid, {operation, put, Scope, CallOptions}, 5000).
get(Pid, Scope, Name, Selector) -> get(Pid, Scope, Name, Selector, #{}).
get(Pid, Scope, _Name, _Selector, CallOptions) ->
    gen_server:call(Pid, {operation, get, Scope, CallOptions}, 5000).
list(Pid, Scope) ->
    gen_server:call(Pid, {operation, list, Scope, #{}}, 5000).
list_names(Pid, Scope, _Options) ->
    gen_server:call(Pid, {operation, list_names, Scope, #{}}, 5000).
list_versions(Pid, Scope, _Name, _Options) ->
    gen_server:call(Pid, {operation, list_versions, Scope, #{}}, 5000).
delete(Pid, Scope, Name, Selector) ->
    delete(Pid, Scope, Name, Selector, #{}).
delete(Pid, Scope, _Name, _Selector, CallOptions) ->
    gen_server:call(Pid, {operation, delete, Scope, CallOptions}, 5000).

add_entry(Pid, Scope, Input, Options) ->
    add_entry(Pid, Scope, Input, Options, #{}).
add_entry(Pid, Scope, _Input, _Options, CallOptions) ->
    gen_server:call(Pid, {operation, add_entry, Scope, CallOptions}, 5000).
add_events(Pid, Scope, SessionId, Events, Options) ->
    add_events(Pid, Scope, SessionId, Events, Options, #{}).
add_events(Pid, Scope, _SessionId, _Events, _Options, CallOptions) ->
    gen_server:call(Pid, {operation, add_events, Scope, CallOptions}, 5000).
add_session_to_memory(Pid, Scope, SessionId, Events, Options) ->
    add_events(Pid, Scope, SessionId, Events, Options).
search(Pid, Scope, Query, Options) ->
    search(Pid, Scope, Query, Options, #{}).
search(Pid, Scope, _Query, _Options, CallOptions) ->
    gen_server:call(Pid, {operation, search, Scope, CallOptions}, 5000).
delete_entry(Pid, Scope, Id) -> delete_entry(Pid, Scope, Id, #{}).
delete_entry(Pid, Scope, _Id, CallOptions) ->
    gen_server:call(Pid, {operation, delete_entry, Scope, CallOptions}, 5000).
delete_session(Pid, Scope, SessionId) ->
    delete_session(Pid, Scope, SessionId, #{}).
delete_session(Pid, Scope, _SessionId, CallOptions) ->
    gen_server:call(Pid, {operation, delete_session, Scope, CallOptions}, 5000).
delete_user(Pid, Scope) -> delete_user(Pid, Scope, #{}).
delete_user(Pid, Scope, CallOptions) ->
    gen_server:call(Pid, {operation, delete_user, Scope, CallOptions}, 5000).

init(Config) ->
    Owner = maps:get(test_owner, Config),
    Mode = maps:get(mode, Config),
    Barrier = maps:get(barrier, Config, false),
    Owner ! {probe_started, self(), Mode},
    {ok, #state{owner = Owner, mode = Mode, barrier = Barrier}}.

handle_call(capabilities, _From, #state{mode = artifact} = State) ->
    {reply, {ok, #{api_version => 1,
                   immutable_versions => true,
                   scopes => [app, user, session],
                   pagination => #{max_page_limit => 10},
                   deadlines => true,
                   persistence => volatile,
                   quotas => #{max_total_bytes => 1024}}}, State};
handle_call(capabilities, _From, #state{mode = memory} = State) ->
    {reply, #{contract_version => 2,
              scope => app_user,
              durable => false,
              search => lexical_overlap,
              idempotent_ingestion => true,
              incremental_events => true,
              delete => [entry, session, user],
              limits => #{}}, State};
handle_call({operation, Operation, Scope, CallOptions}, _From, State) ->
    State#state.owner ! {probe_enter, self(), Operation, Scope, CallOptions},
    maybe_wait_for_release(Scope, State),
    {reply, operation_reply(Operation, Scope), State};
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_probe_request}, State}.

handle_cast(_Message, State) -> {noreply, State}.
handle_info(_Message, State) -> {noreply, State}.

terminate(_Reason, State) ->
    State#state.owner ! {probe_stopped, self(), State#state.mode},
    ok.

code_change(_OldVersion, State, _Extra) -> {ok, State}.

maybe_wait_for_release(Scope, #state{barrier = true}) ->
    receive
        {probe_release, Scope} -> ok
    after 3000 -> ok
    end;
maybe_wait_for_release(_Scope, _State) -> ok.

operation_reply(put, Scope) ->
    {ok, #{scope => Scope, name => <<"probe">>, version => 1,
           mime_type => <<"application/octet-stream">>, digest => <<"00">>,
           size => 0, created_at => 0, metadata => #{}}};
operation_reply(get, Scope) ->
    {ok, #{scope => Scope, name => <<"probe">>, version => 1,
           mime_type => <<"application/octet-stream">>, digest => <<"00">>,
           size => 0, created_at => 0, metadata => #{}, data => <<>>}};
operation_reply(list, _Scope) -> {ok, []};
operation_reply(list_names, Scope) ->
    {ok, #{scope => Scope, items => [], next_cursor => undefined}};
operation_reply(list_versions, _Scope) ->
    {ok, #{items => [], next_cursor => undefined}};
operation_reply(delete, _Scope) -> ok;
operation_reply(add_entry, Scope) ->
    {ok, #{schema_version => 1, id => <<"probe">>, scope => Scope,
           content => <<"probe">>, metadata => #{}, provenance => #{},
           digest => <<"00">>, timestamp => 0}};
operation_reply(add_events, _Scope) ->
    {ok, #{added => 0, duplicates => 0, skipped => 0}};
operation_reply(search, _Scope) -> {ok, []};
operation_reply(delete_entry, _Scope) -> ok;
operation_reply(delete_session, _Scope) -> ok;
operation_reply(delete_user, _Scope) -> ok.
