%% @doc Allocation-bounded reader for untrusted regular files.
%%
%% The metadata check rejects known-oversized and non-regular inputs before
%% opening them. The read itself remains capped at MaxBytes + 1 so a file
%% replaced or grown after that check cannot force an unbounded allocation.
-module(adk_bounded_file).

-include_lib("kernel/include/file.hrl").

-export([read/2]).

-define(CHUNK_BYTES, 65536).

-spec read(file:filename_all(), non_neg_integer()) ->
    {ok, binary()} | {error, file_too_large |
                              {invalid_file_type, atom()} |
                              {file_read_failed, term()}}.
read(Path, MaxBytes) when is_integer(MaxBytes), MaxBytes >= 0 ->
    case file:read_file_info(Path) of
        {ok, #file_info{type = regular, size = Size}}
          when is_integer(Size), Size > MaxBytes ->
            {error, file_too_large};
        {ok, #file_info{type = regular}} ->
            read_regular(Path, MaxBytes);
        {ok, #file_info{type = Type}} ->
            {error, {invalid_file_type, Type}};
        {error, Reason} ->
            {error, {file_read_failed, Reason}}
    end;
read(_Path, _MaxBytes) ->
    {error, {file_read_failed, badarg}}.

read_regular(Path, MaxBytes) ->
    case file:open(Path, [read, binary, raw]) of
        {ok, IoDevice} ->
            try read_chunks(IoDevice, MaxBytes + 1, 0, [])
            after
                _ = file:close(IoDevice)
            end;
        {error, Reason} ->
            {error, {file_read_failed, Reason}}
    end.

read_chunks(_IoDevice, Limit, Bytes, _Acc) when Bytes >= Limit ->
    {error, file_too_large};
read_chunks(IoDevice, Limit, Bytes, Acc) ->
    ReadSize = erlang:min(?CHUNK_BYTES, Limit - Bytes),
    case file:read(IoDevice, ReadSize) of
        {ok, Chunk} when is_binary(Chunk), byte_size(Chunk) > 0 ->
            NewBytes = Bytes + byte_size(Chunk),
            case NewBytes >= Limit of
                true -> {error, file_too_large};
                false -> read_chunks(
                           IoDevice, Limit, NewBytes, [Chunk | Acc])
            end;
        eof -> {ok, iolist_to_binary(lists:reverse(Acc))};
        {error, Reason} -> {error, {file_read_failed, Reason}}
    end.
