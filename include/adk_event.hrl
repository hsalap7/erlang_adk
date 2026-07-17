-record(adk_event, {
    id            :: binary(),
    invocation_id :: binary(),
    author        :: binary(),          %% <<"user">> | agent name
    content       :: term(),            %% text | adk_content | tool call/response
    actions       :: map(),             %% #{state_delta => #{}, transfer_to_agent => ...}
    timestamp     :: integer(),
    partial       :: boolean(),         %% true = streaming chunk
    is_final      :: boolean()
}).
