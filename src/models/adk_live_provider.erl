%% @doc Provider adapter contract for bidirectional Live sessions.
%%
%% Provider adapters validate an immutable setup, produce one setup frame,
%% encode admitted client actions, and decode each provider frame into an
%% ordered list of provider-neutral event specifications.  They do not own
%% sockets or process lifetimes.
-module(adk_live_provider).

-type client_action() ::
    {text, binary()} |
    {audio, adk_live_media:media()} |
    {video_frame, adk_live_media:media()} |
    activity_start | activity_end | audio_stream_end |
    {tool_response, binary(), binary(), map()}.
-type event_spec() :: #{kind := atom(), payload := term()}.

-export_type([client_action/0, event_spec/0]).

-callback capabilities() -> map().
-callback validate_config(map()) -> {ok, map()} | {error, term()}.
-callback setup_frame(map()) -> {ok, binary()} | {error, term()}.
-callback resume_setup_frame(map(), binary()) ->
    {ok, binary()} | {error, term()}.
-callback encode_client(client_action(), map()) ->
    {ok, binary()} | {error, term()}.
-callback decode_server(binary(), map()) ->
    {ok, [event_spec()]} | {error, term()}.

-optional_callbacks([resume_setup_frame/2]).
