%%%-------------------------------------------------------------------
%% @doc erlang_adk public API
%% @end
%%%-------------------------------------------------------------------

-module(erlang_adk_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    case configure_oidcc() of
        ok -> start_after_oidcc();
        {error, _} = Error -> Error
    end.

stop(_State) ->
    ok.

%% internal functions

start_after_oidcc() ->
    case init_configured_session_backend() of
        ok -> erlang_adk_sup:start_link();
        {error, _} = Error -> Error
    end.

%% Oidcc performs its standard JWT time checks before adk_jwt_policy applies
%% the issuer-specific policy. Configure the dependency to accept the widest
%% skew this library permits; adk_jwt_policy then independently enforces the
%% narrower value selected for each issuer.
configure_oidcc() ->
    case application:get_env(
           erlang_adk, oidc_max_clock_skew_seconds, 300) of
        Seconds when is_integer(Seconds), Seconds >= 0, Seconds =< 300 ->
            application:set_env(oidcc, max_clock_skew, Seconds);
        Invalid ->
            {error, {invalid_oidc_max_clock_skew_seconds, Invalid}}
    end.

init_configured_session_backend() ->
    case application:get_env(erlang_adk, session_backend, undefined) of
        undefined -> ok;
        erlang_adk_session -> ok;
        Backend when is_atom(Backend) -> init_session_backend(Backend);
        Invalid -> {error, {invalid_session_backend, Invalid}}
    end.

init_session_backend(Backend) ->
    case code:ensure_loaded(Backend) of
        {module, Backend} ->
            case erlang:function_exported(Backend, init, 0) of
                false -> ok;
                true -> call_session_backend_init(Backend)
            end;
        {error, Reason} ->
            {error, adk_failure:external(
                      application, session_backend_load, Reason)}
    end.

call_session_backend_init(Backend) ->
    try Backend:init() of
        ok -> ok;
        {atomic, ok} -> ok;
        {error, Reason} ->
            {error, adk_failure:external(
                      application, session_backend_init, Reason)};
        Other ->
            {error, adk_failure:external(
                      application, session_backend_init_result, Other)}
    catch
        Class:Reason:_Stacktrace ->
            {error, adk_failure:exception(
                      application, session_backend_init, Class, Reason)}
    end.
