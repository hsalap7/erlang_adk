%% @doc Per-adapter supervisor for temporary artifact transfer workers.
-module(adk_artifact_stream_sup).
-behaviour(supervisor).

-export([start_link/0, start_upload/7, start_download/5]).
-export([init/1]).

-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    supervisor:start_link(?MODULE, []).

-spec start_upload(pid(), {module(), term()}, adk_artifact_service:scope(),
                   binary(), map(), map(), map()) ->
    {ok, adk_artifact_stream:stream(), map()} | {error, term()}.
start_upload(Supervisor, Backend, Scope, Name, PutOptions,
             StreamOptions, Limits) ->
    start_child(Supervisor,
                #{mode => upload, backend => Backend, scope => Scope,
                  name => Name, put_options => PutOptions,
                  stream_options => StreamOptions, limits => Limits}).

-spec start_download(pid(), map(), map(), map(), map()) ->
    {ok, adk_artifact_stream:stream(), map()} | {error, term()}.
start_download(Supervisor, Artifact, StreamOptions, Limits, BackendInfo) ->
    start_child(Supervisor,
                #{mode => download, artifact => Artifact,
                  stream_options => StreamOptions, limits => Limits,
                  backend_info => BackendInfo}).

start_child(Supervisor, Args) when is_pid(Supervisor) ->
    case supervisor:start_child(Supervisor, [Args]) of
        {ok, Pid} -> adk_artifact_stream_worker:description(Pid);
        {ok, Pid, _Info} -> adk_artifact_stream_worker:description(Pid);
        {error, _} = Error -> Error
    end;
start_child(_Supervisor, _Args) ->
    {error, invalid_stream_supervisor}.

init([]) ->
    Flags = #{strategy => simple_one_for_one, intensity => 10, period => 10},
    Child = #{id => adk_artifact_stream_worker,
              start => {adk_artifact_stream_worker, start_link, []},
              restart => temporary,
              shutdown => 5000,
              type => worker,
              modules => [adk_artifact_stream_worker]},
    {ok, {Flags, [Child]}}.
