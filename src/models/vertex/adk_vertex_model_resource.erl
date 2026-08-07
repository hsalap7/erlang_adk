%% @doc Strict resolver for the supported Vertex AI publisher-model target.
%%
%% The adapter accepts only a complete Google publisher resource. The project,
%% location, publisher, and model are therefore one operator-owned value; no
%% caller-controlled host or path is combined with ambient credentials.
-module(adk_vertex_model_resource).

-export([parse/1, generate_path/1, stream_path/1]).

-define(MAX_RESOURCE_BYTES, 512).
-define(MAX_PROJECT_BYTES, 128).
%% Regional origins prefix the location to the 11-byte "-aiplatform" suffix.
%% Keep the resulting DNS label within the RFC 63-byte label ceiling.
-define(MAX_LOCATION_BYTES, 52).
-define(MAX_MODEL_BYTES, 256).

-type target() :: #{resource := binary(),
                    project := binary(),
                    location := binary(),
                    publisher := google,
                    model := binary(),
                    base_url := binary()}.
-export_type([target/0]).

-spec parse(term()) -> {ok, target()} |
                       {error, invalid_vertex_model_resource}.
parse(Resource)
  when is_binary(Resource), byte_size(Resource) > 0,
       byte_size(Resource) =< ?MAX_RESOURCE_BYTES ->
    case binary:split(Resource, <<"/">>, [global]) of
        [<<"projects">>, Project, <<"locations">>, Location,
         <<"publishers">>, <<"google">>, <<"models">>, Model] ->
            case valid_project(Project) andalso valid_location(Location)
                 andalso valid_model(Model) of
                true ->
                    {ok, #{resource => Resource,
                           project => Project,
                           location => Location,
                           publisher => google,
                           model => Model,
                           base_url => base_url(Location)}};
                false -> {error, invalid_vertex_model_resource}
            end;
        _ -> {error, invalid_vertex_model_resource}
    end;
parse(_Resource) ->
    {error, invalid_vertex_model_resource}.

-spec generate_path(target()) -> binary().
generate_path(#{resource := Resource}) ->
    <<"/v1/", Resource/binary, ":generateContent">>.

-spec stream_path(target()) -> binary().
stream_path(#{resource := Resource}) ->
    <<"/v1/", Resource/binary, ":streamGenerateContent">>.

base_url(<<"global">>) ->
    <<"https://aiplatform.googleapis.com">>;
base_url(Location) ->
    <<"https://", Location/binary, "-aiplatform.googleapis.com">>.

valid_project(Value) ->
    valid_segment(Value, ?MAX_PROJECT_BYTES,
                  fun project_char/1) andalso segment_edges_are_alnum(Value).

valid_location(Value) ->
    valid_segment(Value, ?MAX_LOCATION_BYTES,
                  fun location_char/1) andalso
        lower_ascii(Value) andalso segment_edges_are_alnum(Value).

valid_model(Value) ->
    valid_segment(Value, ?MAX_MODEL_BYTES,
                  fun model_char/1) andalso segment_edges_are_alnum(Value).

valid_segment(Value, Maximum, CharFun)
  when is_binary(Value), byte_size(Value) > 0,
       byte_size(Value) =< Maximum ->
    lists:all(CharFun, binary_to_list(Value));
valid_segment(_Value, _Maximum, _CharFun) -> false.

project_char(Char) ->
    alpha_numeric(Char) orelse lists:member(Char, "._-").

location_char(Char) ->
    (Char >= $a andalso Char =< $z) orelse
    (Char >= $0 andalso Char =< $9) orelse Char =:= $-.

model_char(Char) ->
    alpha_numeric(Char) orelse lists:member(Char, "._@-").

segment_edges_are_alnum(Value) ->
    alpha_numeric(binary:at(Value, 0)) andalso
        alpha_numeric(binary:last(Value)).

alpha_numeric(Char) ->
    (Char >= $a andalso Char =< $z) orelse
    (Char >= $A andalso Char =< $Z) orelse
    (Char >= $0 andalso Char =< $9).

lower_ascii(Value) ->
    lists:all(
      fun(Char) -> not (Char >= $A andalso Char =< $Z) end,
      binary_to_list(Value)).
