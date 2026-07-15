%% @doc Strict, atom-safe Gemini safety-setting normalization and REST encoding.
%%
%% The adjustable Gemini filters are deliberately represented with a small
%% Erlang atom vocabulary.  No value is converted to an atom at runtime.
-module(adk_gemini_safety).

-export([normalize/1, encode/1]).

-type category() :: adk_safety_settings:category().
-type threshold() :: adk_safety_settings:threshold().
-type setting() :: adk_safety_settings:setting().

-export_type([category/0, threshold/0, setting/0]).

-spec normalize(term()) -> {ok, [setting()]} | {error, term()}.
normalize(Settings) ->
    adk_safety_settings:normalize(Settings).

-spec encode(term()) -> {ok, [map()]} | {error, term()}.
encode(Settings) ->
    case normalize(Settings) of
        {ok, Canonical} ->
            {ok, [#{<<"category">> => category_json(Category),
                    <<"threshold">> => threshold_json(Threshold)}
                  || #{category := Category, threshold := Threshold}
                         <- Canonical]};
        {error, _} = Error -> Error
    end.

category_json(harassment) -> <<"HARM_CATEGORY_HARASSMENT">>;
category_json(hate_speech) -> <<"HARM_CATEGORY_HATE_SPEECH">>;
category_json(sexually_explicit) ->
    <<"HARM_CATEGORY_SEXUALLY_EXPLICIT">>;
category_json(dangerous_content) ->
    <<"HARM_CATEGORY_DANGEROUS_CONTENT">>.

threshold_json(off) -> <<"OFF">>;
threshold_json(block_none) -> <<"BLOCK_NONE">>;
threshold_json(block_only_high) -> <<"BLOCK_ONLY_HIGH">>;
threshold_json(block_medium_and_above) -> <<"BLOCK_MEDIUM_AND_ABOVE">>;
threshold_json(block_low_and_above) -> <<"BLOCK_LOW_AND_ABOVE">>;
threshold_json(unspecified) -> <<"HARM_BLOCK_THRESHOLD_UNSPECIFIED">>.
