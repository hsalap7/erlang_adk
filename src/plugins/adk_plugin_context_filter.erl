%% @doc Deterministic before_model context filter.
-module(adk_plugin_context_filter).
-behaviour(adk_plugin).

-export([before_model/3]).

before_model(_Context, Request, Config) when is_map(Request), is_map(Config) ->
    Memory = maps:get(memory, Request, []),
    case normalize_config(Config) of
        {ok, Policy} when is_list(Memory) ->
            Filtered0 = [Message || Message <- Memory,
                                    keep_message(Message, Policy)],
            Filtered1 = preserve_required(Memory, Filtered0, Policy),
            Filtered = apply_limit(Filtered1, Policy),
            {amend, Request#{memory => Filtered}};
        {ok, _Policy} -> erlang:error(invalid_context_filter_memory);
        {error, Reason} -> erlang:error(Reason)
    end;
before_model(_Context, _Request, _Config) ->
    erlang:error(invalid_context_filter_request).

normalize_config(Config) ->
    Unknown = maps:without(
                [max_messages, include_roles, exclude_roles,
                 preserve_system, preserve_latest_user], Config),
    Max = maps:get(max_messages, Config, infinity),
    Include = maps:get(include_roles, Config, all),
    Exclude = maps:get(exclude_roles, Config, []),
    PreserveSystem = maps:get(preserve_system, Config, true),
    PreserveUser = maps:get(preserve_latest_user, Config, true),
    case map_size(Unknown) =:= 0 andalso valid_max(Max) andalso
         valid_roles(Include) andalso valid_roles(Exclude) andalso
         is_boolean(PreserveSystem) andalso is_boolean(PreserveUser) of
        true ->
            {ok, #{max_messages => Max,
                   include_roles => normalize_roles(Include),
                   exclude_roles => normalize_roles(Exclude),
                   preserve_system => PreserveSystem,
                   preserve_latest_user => PreserveUser}};
        false -> {error, invalid_context_filter_plugin_config}
    end.

valid_max(infinity) -> true;
valid_max(Max) -> is_integer(Max) andalso Max > 0.

valid_roles(all) -> true;
valid_roles(Roles) when is_list(Roles) ->
    lists:all(fun valid_role/1, Roles);
valid_roles(_) -> false.

valid_role(Role) when is_atom(Role); is_binary(Role) -> true;
valid_role(_) -> false.

normalize_roles(all) -> all;
normalize_roles(Roles) -> [role_binary(Role) || Role <- Roles].

keep_message(#{role := Role}, Policy) ->
    RoleBin = role_binary(Role),
    Include = maps:get(include_roles, Policy),
    Exclude = maps:get(exclude_roles, Policy),
    (Include =:= all orelse lists:member(RoleBin, Include)) andalso
        not lists:member(RoleBin, Exclude);
keep_message(_Message, _Policy) -> false.

preserve_required(Original, Filtered, Policy) ->
    WithSystem = case maps:get(preserve_system, Policy) of
        true -> add_first_missing_role(<<"system">>, Original, Filtered);
        false -> Filtered
    end,
    case maps:get(preserve_latest_user, Policy) of
        true -> add_first_missing_role(<<"user">>, Original, WithSystem);
        false -> WithSystem
    end.

add_first_missing_role(Role, Original, Filtered) ->
    case lists:any(fun(Message) -> message_role(Message) =:= Role end,
                   Filtered) of
        true -> Filtered;
        false ->
            case lists:dropwhile(
                   fun(Message) -> message_role(Message) =/= Role end,
                   Original) of
                [Message | _] -> insert_in_original_order(
                                   Message, Original, Filtered);
                [] -> Filtered
            end
    end.

insert_in_original_order(Message, Original, Filtered) ->
    Selected = [Candidate || Candidate <- Original,
                             Candidate =:= Message orelse
                             lists:member(Candidate, Filtered)],
    deduplicate(Selected, []).

deduplicate([], Acc) -> lists:reverse(Acc);
deduplicate([Item | Rest], Acc) ->
    case lists:member(Item, Acc) of
        true -> deduplicate(Rest, Acc);
        false -> deduplicate(Rest, [Item | Acc])
    end.

apply_limit(Memory, #{max_messages := infinity}) -> Memory;
apply_limit(Memory, #{max_messages := Max}) ->
    Systems = [Message || Message <- Memory,
                           message_role(Message) =:= <<"system">>],
    Others = [Message || Message <- Memory,
                          message_role(Message) =/= <<"system">>],
    SelectedOthers = lists:sublist(Others, Max),
    [Message || Message <- Memory,
                lists:member(Message, Systems) orelse
                lists:member(Message, SelectedOthers)].

message_role(#{role := Role}) -> role_binary(Role);
message_role(_) -> <<>>.

role_binary(Role) when is_atom(Role) -> atom_to_binary(Role, utf8);
role_binary(Role) when is_binary(Role) -> Role.
