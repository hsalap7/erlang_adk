%% @doc Bounded structural validation for the process-backed agent tree.
%%
%% Public agents are independent OTP processes, so a parent receives child
%% references rather than owning mutable child objects.  Validation therefore
%% walks the immutable runtime descriptions exposed by already-started child
%% agents.  The walk is deliberately bounded by node count, depth, and one
%% overall deadline so malformed or unresponsive references cannot turn agent
%% creation into an unbounded operation.
-module(adk_agent_tree).

-export([validate/2, validate_name/1]).

-define(MAX_NODES, 256).
-define(MAX_DEPTH, 64).
-define(VALIDATION_TIMEOUT_MS, 2000).

-type name_error() :: reserved_user | invalid_identifier.

-spec validate(term(), term()) -> ok | {error, {invalid_agent_tree, term()}}.
validate(Name, Config) when is_map(Config) ->
    case validate_name(Name) of
        {error, Reason} ->
            invalid({invalid_name, root, Reason});
        {ok, RootName} ->
            case maps:get(sub_agents, Config, #{}) of
                SubAgents when is_map(SubAgents) ->
                    Deadline = erlang:monotonic_time(millisecond)
                               + ?VALIDATION_TIMEOUT_MS,
                    State = #{root_name => RootName,
                              names => #{RootName => true},
                              pids => #{},
                              node_count => 1,
                              deadline => Deadline},
                    case normalize_children(SubAgents, RootName) of
                        {ok, Children} ->
                            validation_result(
                              walk_children(Children, #{}, 1, State));
                        {error, Reason} -> invalid(Reason)
                    end;
                _ ->
                    invalid(invalid_sub_agents)
            end
    end;
validate(_Name, _Config) ->
    invalid(invalid_agent_config).

%% ADK agent names are model-visible identifiers.  At the Erlang boundary we
%% accept the existing string/binary/atom name forms, but normalize them to a
%% binary and enforce the same portable identifier grammar used by ADK tool
%% declarations.  `user' is reserved as the event author for end-user input.
-spec validate_name(term()) -> {ok, binary()} | {error, name_error()}.
validate_name(Name) ->
    case normalize_name(Name) of
        {ok, <<"user">>} -> {error, reserved_user};
        {ok, NameBin} ->
            case valid_identifier(NameBin) of
                true -> {ok, NameBin};
                false -> {error, invalid_identifier}
            end;
        error ->
            {error, invalid_identifier}
    end.

validation_result({ok, _State}) -> ok;
validation_result({error, Reason}) -> invalid(Reason).

invalid(Reason) ->
    {error, {invalid_agent_tree, Reason}}.

normalize_children(SubAgents, RootName) ->
    normalize_children(
      lists:sort(maps:to_list(SubAgents)), RootName, #{}, []).

normalize_children([], _RootName, _LocalNames, Acc) ->
    {ok, lists:sort(Acc)};
normalize_children([{RawName, Spec} | Rest], RootName, LocalNames, Acc) ->
    case validate_name(RawName) of
        {error, Reason} ->
            {error, {invalid_name, sub_agent, Reason}};
        {ok, RootName} ->
            {error, {self_reference, RootName}};
        {ok, Name} ->
            case maps:is_key(Name, LocalNames) of
                true ->
                    {error, {duplicate_name, Name}};
                false ->
                    normalize_children(
                      Rest, RootName, LocalNames#{Name => true},
                      [{Name, Spec} | Acc])
            end
    end.

walk_children([], _PathPids, _Depth, State) ->
    {ok, State};
walk_children([{Name, Spec} | Rest], PathPids, Depth, State0) ->
    case walk_child(Name, Spec, PathPids, Depth, State0) of
        {ok, State1} -> walk_children(Rest, PathPids, Depth, State1);
        {error, _} = Error -> Error
    end.

walk_child(Name, _Spec, _PathPids, Depth, _State)
  when Depth > ?MAX_DEPTH ->
    {error, {tree_limit_exceeded, max_depth, Name}};
walk_child(Name, Spec, PathPids, Depth, State0) ->
    case maps:get(node_count, State0) >= ?MAX_NODES of
        true ->
            {error, {tree_limit_exceeded, max_nodes, Name}};
        false ->
            walk_child_within_limits(
              Name, Spec, PathPids, Depth, State0)
    end.

walk_child_within_limits(Name, Spec, PathPids, Depth, State0) ->
    case resolve_pid(Name, Spec) of
        {error, Reason} ->
            {error, Reason};
        {ok, Pid} ->
            case maps:is_key(Pid, PathPids) of
                true ->
                    {error, {cycle, Name}};
                false ->
                    walk_new_child(Name, Pid, PathPids, Depth, State0)
            end
    end.

walk_new_child(Name, Pid, PathPids, Depth, State0) ->
    Names = maps:get(names, State0),
    Pids = maps:get(pids, State0),
    case {maps:is_key(Name, Names), maps:is_key(Pid, Pids)} of
        {true, _} ->
            {error, {duplicate_name, Name}};
        {false, true} ->
            {error, {agent_has_multiple_parents, Name}};
        {false, false} ->
            fetch_and_walk_child(Name, Pid, PathPids, Depth, State0)
    end.

fetch_and_walk_child(Name, Pid, PathPids, Depth, State0) ->
    case fetch_runtime(Pid, maps:get(deadline, State0)) of
        {ok, RuntimeName, SubAgents} ->
            case validate_runtime_name(Name, RuntimeName) of
                ok ->
                    case normalize_children(
                           SubAgents, maps:get(root_name, State0)) of
                        {error, Reason} ->
                            {error, Reason};
                        {ok, Children} ->
                            Names = maps:get(names, State0),
                            Pids = maps:get(pids, State0),
                            State1 = State0#{
                              names => Names#{Name => true},
                              pids => Pids#{Pid => true},
                              node_count => maps:get(node_count, State0) + 1},
                            walk_children(
                              Children, PathPids#{Pid => true},
                              Depth + 1, State1)
                    end;
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

validate_runtime_name(DeclaredName, RuntimeName) ->
    case validate_name(RuntimeName) of
        {error, Reason} ->
            {error, {invalid_name, child_runtime, Reason}};
        {ok, DeclaredName} ->
            ok;
        {ok, ActualName} ->
            {error, {sub_agent_name_mismatch,
                     DeclaredName, ActualName}}
    end.

resolve_pid(Name, #{pid := Pid}) when is_pid(Pid) ->
    resolve_live_pid(Name, Pid);
resolve_pid(Name, Pid) when is_pid(Pid) ->
    resolve_live_pid(Name, Pid);
resolve_pid(Name, _Other) ->
    lookup_registered(Name).

resolve_live_pid(Name, Pid) ->
    case catch erlang:is_process_alive(Pid) of
        true -> {ok, Pid};
        _ -> lookup_registered(Name)
    end.

lookup_registered(Name) ->
    case catch adk_agent_registry:whereis_name(Name) of
        Pid when is_pid(Pid) -> {ok, Pid};
        _ -> {error, {unavailable_sub_agent, Name}}
    end.

fetch_runtime(Pid, Deadline) ->
    Remaining = Deadline - erlang:monotonic_time(millisecond),
    case Remaining > 0 of
        false ->
            {error, agent_tree_validation_timeout};
        true ->
            try gen_server:call(Pid, get_runtime, Remaining) of
                {ok, RuntimeName, Config, Tools, SubAgents}
                  when is_map(Config), is_list(Tools), is_map(SubAgents) ->
                    {ok, RuntimeName, SubAgents};
                _Other ->
                    {error, invalid_sub_agent_runtime}
            catch
                exit:{timeout, _} ->
                    {error, agent_tree_validation_timeout};
                exit:{noproc, _} ->
                    {error, unavailable_sub_agent};
                exit:_Reason ->
                    {error, unavailable_sub_agent}
            end
    end.

normalize_name(Name) when is_binary(Name) ->
    {ok, Name};
normalize_name(Name) when is_atom(Name) ->
    {ok, atom_to_binary(Name, utf8)};
normalize_name(Name) when is_list(Name) ->
    try unicode:characters_to_binary(Name) of
        NameBin when is_binary(NameBin) -> {ok, NameBin};
        _ -> error
    catch
        _:_ -> error
    end;
normalize_name(_Name) ->
    error.

valid_identifier(<<First, Rest/binary>>) ->
    valid_identifier_start(First) andalso valid_identifier_rest(Rest);
valid_identifier(<<>>) ->
    false.

valid_identifier_start(Char) ->
    Char =:= $_ orelse
    (Char >= $a andalso Char =< $z) orelse
    (Char >= $A andalso Char =< $Z).

valid_identifier_rest(<<>>) ->
    true;
valid_identifier_rest(<<Char, Rest/binary>>) ->
    (valid_identifier_start(Char) orelse
     (Char >= $0 andalso Char =< $9))
    andalso valid_identifier_rest(Rest).
