%% @doc before_model plugin that prepends or appends a bounded global
%% instruction to the system message without changing provider authority.
-module(adk_plugin_global_instruction).
-behaviour(adk_plugin).

-export([before_model/3]).

-define(MAX_INSTRUCTION_BYTES, 65536).

before_model(_Context, Request, Config) when is_map(Request), is_map(Config) ->
    Instruction = maps:get(instruction, Config, undefined),
    Position = maps:get(position, Config, prepend),
    Separator = maps:get(separator, Config, <<"\n\n">>),
    case valid_config(Instruction, Position, Separator) of
        true ->
            Memory = maps:get(memory, Request, []),
            {amend, Request#{memory =>
                                 inject_instruction(
                                   Memory, Instruction,
                                   Position, Separator)}};
        false -> erlang:error(invalid_global_instruction_plugin_config)
    end;
before_model(_Context, _Request, _Config) ->
    erlang:error(invalid_global_instruction_plugin_request).

valid_config(Instruction, Position, Separator) ->
    is_binary(Instruction) andalso byte_size(Instruction) > 0 andalso
    byte_size(Instruction) =< ?MAX_INSTRUCTION_BYTES andalso
    (Position =:= prepend orelse Position =:= append) andalso
    is_binary(Separator) andalso byte_size(Separator) =< 16 andalso
    valid_utf8(Instruction) andalso valid_utf8(Separator).

inject_instruction(Memory, Instruction, Position, Separator)
  when is_list(Memory) ->
    case inject_existing_system(
           Memory, Instruction, Position, Separator, []) of
        {found, Updated} -> Updated;
        not_found ->
            Memory ++ [#{role => system, content => Instruction,
                         timestamp => erlang:system_time(millisecond)}]
    end;
inject_instruction(_Memory, _Instruction, _Position, _Separator) ->
    erlang:error(invalid_global_instruction_memory).

inject_existing_system([], _Instruction, _Position, _Separator, _Acc) ->
    not_found;
inject_existing_system([#{role := Role, content := Existing} = Message |
                        Rest], Instruction, Position, Separator, Acc)
  when (Role =:= system orelse Role =:= <<"system">>),
       is_binary(Existing) ->
    Content = case Position of
        prepend -> <<Instruction/binary, Separator/binary, Existing/binary>>;
        append -> <<Existing/binary, Separator/binary, Instruction/binary>>
    end,
    {found, lists:reverse(Acc) ++ [Message#{content => Content} | Rest]};
inject_existing_system([Message | Rest], Instruction, Position,
                       Separator, Acc) ->
    inject_existing_system(
      Rest, Instruction, Position, Separator, [Message | Acc]).

valid_utf8(Binary) ->
    case unicode:characters_to_binary(Binary, utf8, utf8) of
        Binary -> true;
        _ -> false
    end.
