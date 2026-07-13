%%%-------------------------------------------------------------------
%% @doc erlang_adk public API
%% @end
%%%-------------------------------------------------------------------

-module(erlang_adk_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    %% Preserve the application's existing Mnesia backend bootstrap. The ETS
    %% backend is now initialized by its supervised owner below, but Mnesia is
    %% an independent session backend and still needs its tables at app start.
    erlang_adk_session_mnesia:init(),
    case erlang_adk_sup:start_link() of
        {ok, SupPid} ->
            maybe_start_a2a_listener(),
            {ok, SupPid};
        Error ->
            Error
    end.

stop(_State) ->
    _ = catch cowboy:stop_listener(erlang_adk_a2a_http),
    ok.

%% internal functions

maybe_start_a2a_listener() ->
    case application:get_env(erlang_adk, a2a_enabled, true) of
        false -> ok;
        true ->
            Port = application:get_env(erlang_adk, a2a_port, 8080),
            Dispatch = cowboy_router:compile([
                {'_', [{"/a2a/prompt", erlang_adk_a2a_handler, []}]}
            ]),
            case cowboy:start_clear(erlang_adk_a2a_http,
                                    [{port, Port}],
                                    #{env => #{dispatch => Dispatch}}) of
                {ok, _} -> ok;
                {error, {already_started, _}} -> ok;
                {error, Reason} ->
                    logger:warning("A2A listener disabled: ~p", [Reason]),
                    ok
            end
    end.
