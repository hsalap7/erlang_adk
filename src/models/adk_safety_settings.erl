%% @doc Provider-neutral safety-setting contract used by agent specifications.
%%
%% Providers encode the canonical categories and thresholds for their own
%% wire protocol. Values are normalized without creating atoms at runtime.
-module(adk_safety_settings).

-export([normalize/1]).

-type category() :: harassment | hate_speech | sexually_explicit |
                    dangerous_content.
-type threshold() :: off | block_none | block_only_high |
                     block_medium_and_above | block_low_and_above |
                     unspecified.
-type setting() :: #{category := category(), threshold := threshold()}.

-export_type([category/0, threshold/0, setting/0]).

-spec normalize(term()) -> {ok, [setting()]} | {error, term()}.
normalize(Settings) when is_list(Settings), length(Settings) =< 4 ->
    normalize_settings(Settings, 0, #{}, []);
normalize(Settings) when is_list(Settings) ->
    {error, too_many_safety_settings};
normalize(_Settings) ->
    {error, expected_list}.

normalize_settings([], _Index, _Seen, Acc) ->
    {ok, lists:reverse(Acc)};
normalize_settings([Setting | Rest], Index, Seen, Acc) when is_map(Setting) ->
    case maps:without([category, threshold], Setting) of
        Unknown when map_size(Unknown) > 0 ->
            {error, {invalid_setting, Index,
                     {unknown_keys, lists:sort(maps:keys(Unknown))}}};
        _ ->
            normalize_setting(Rest, Setting, Index, Seen, Acc)
    end;
normalize_settings([_Setting | _Rest], Index, _Seen, _Acc) ->
    {error, {invalid_setting, Index, expected_map}}.

normalize_setting(Rest, Setting, Index, Seen, Acc) ->
    case {normalize_category(maps:get(category, Setting, undefined)),
          normalize_threshold(maps:get(threshold, Setting, undefined))} of
        {{ok, Category}, {ok, Threshold}} ->
            case maps:is_key(Category, Seen) of
                true -> {error, {duplicate_category, Category}};
                false ->
                    Canonical = #{category => Category,
                                  threshold => Threshold},
                    normalize_settings(Rest, Index + 1,
                                       Seen#{Category => true},
                                       [Canonical | Acc])
            end;
        {error, _} ->
            {error, {invalid_setting, Index, invalid_category}};
        {_, error} ->
            {error, {invalid_setting, Index, invalid_threshold}}
    end.

normalize_category(harassment) -> {ok, harassment};
normalize_category(hate_speech) -> {ok, hate_speech};
normalize_category(sexually_explicit) -> {ok, sexually_explicit};
normalize_category(dangerous_content) -> {ok, dangerous_content};
normalize_category(<<"HARM_CATEGORY_HARASSMENT">>) -> {ok, harassment};
normalize_category(<<"HARM_CATEGORY_HATE_SPEECH">>) -> {ok, hate_speech};
normalize_category(<<"HARM_CATEGORY_SEXUALLY_EXPLICIT">>) ->
    {ok, sexually_explicit};
normalize_category(<<"HARM_CATEGORY_DANGEROUS_CONTENT">>) ->
    {ok, dangerous_content};
normalize_category(_) -> error.

normalize_threshold(off) -> {ok, off};
normalize_threshold(block_none) -> {ok, block_none};
normalize_threshold(block_only_high) -> {ok, block_only_high};
normalize_threshold(block_medium_and_above) ->
    {ok, block_medium_and_above};
normalize_threshold(block_low_and_above) -> {ok, block_low_and_above};
normalize_threshold(unspecified) -> {ok, unspecified};
normalize_threshold(<<"OFF">>) -> {ok, off};
normalize_threshold(<<"BLOCK_NONE">>) -> {ok, block_none};
normalize_threshold(<<"BLOCK_ONLY_HIGH">>) -> {ok, block_only_high};
normalize_threshold(<<"BLOCK_MEDIUM_AND_ABOVE">>) ->
    {ok, block_medium_and_above};
normalize_threshold(<<"BLOCK_LOW_AND_ABOVE">>) ->
    {ok, block_low_and_above};
normalize_threshold(<<"HARM_BLOCK_THRESHOLD_UNSPECIFIED">>) ->
    {ok, unspecified};
normalize_threshold(_) -> error.
