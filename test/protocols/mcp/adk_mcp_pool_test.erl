-module(adk_mcp_pool_test).
-include_lib("eunit/include/eunit.hrl").

fifo_checkout_and_explicit_cancel_test() ->
    {ok, Pool} = pool(1, self()),
    try
        {ok, Lease1, _Connection1} = adk_mcp_pool:checkout(Pool, 1000),
        Parent = self(),
        First = spawn(fun() ->
            Parent ! first_waiting,
            Result = adk_mcp_pool:checkout(Pool, 2000),
            Parent ! {first, Result},
            receive
                cancel ->
                    {ok, OwnedLease, _} = Result,
                    Parent ! {first_cancelled,
                              adk_mcp_pool:cancel(Pool, OwnedLease)}
            end
        end),
        receive first_waiting -> ok end,
        wait_waiters(Pool, 1),
        Second = spawn(fun() ->
            Parent ! second_waiting,
            Result = adk_mcp_pool:checkout(Pool, 2000),
            Parent ! {second, Result},
            receive stop -> ok end
        end),
        receive second_waiting -> ok end,
        wait_waiters(Pool, 2),
        ok = adk_mcp_pool:checkin(Pool, Lease1, healthy),
        Lease2 = receive
            {first, {ok, FirstLease, _}} -> FirstLease;
            {second, _} -> error(second_waiter_won)
        after 1000 -> error(first_waiter_timed_out)
        end,
        %% The lease belongs to First, so this process cannot cancel it.
        ?assertEqual({error, invalid_mcp_pool_lease},
                     adk_mcp_pool:cancel(Pool, Lease2)),
        First ! cancel,
        receive {first_cancelled, ok} -> ok after 1000 -> error(cancel_failed) end,
        receive {second, {ok, Lease3, _Connection3}} ->
            Second ! stop,
            %% Borrower death safely discards the lease; no foreign check-in.
            ?assert(is_reference(Lease3))
        after 2000 -> error(second_waiter_timed_out)
        end
    after
        ok = adk_mcp_pool:stop(Pool)
    end.

mutation_disconnect_is_not_replayed_and_pool_reconnects_test() ->
    Counter = atomics:new(1, []),
    Connect = fun() -> {ok, {connection, atomics:add_get(Counter, 1, 1)}} end,
    {ok, Pool} = adk_mcp_pool:start_link(
                   #{connect_fun => Connect, max_size => 1}),
    try
        Invocations = atomics:new(1, []),
        Result = adk_mcp_pool:request(
                   Pool, mutation,
                   fun(_Connection) ->
                       _ = atomics:add_get(Invocations, 1, 1),
                       {error, disconnected}
                   end, 1000),
        ?assertEqual({error, {delivery_uncertain, not_replayed}}, Result),
        ?assertEqual(1, atomics:get(Invocations, 1)),
        {ok, Lease, {connection, 2}} = adk_mcp_pool:checkout(Pool, 1000),
        ok = adk_mcp_pool:checkin(Pool, Lease, healthy)
    after
        ok = adk_mcp_pool:stop(Pool)
    end.

waiting_timeout_is_removed_test() ->
    {ok, Pool} = pool(1, self()),
    try
        {ok, Lease, _} = adk_mcp_pool:checkout(Pool, 1000),
        ?assertEqual({error, mcp_pool_checkout_timeout},
                     adk_mcp_pool:checkout(Pool, 20)),
        {ok, #{waiting := 0}} = adk_mcp_pool:status(Pool),
        ok = adk_mcp_pool:checkin(Pool, Lease, healthy)
    after
        ok = adk_mcp_pool:stop(Pool)
    end.

pool(Max, Owner) ->
    Counter = atomics:new(1, []),
    adk_mcp_pool:start_link(
      #{max_size => Max,
        connect_fun => fun() ->
            N = atomics:add_get(Counter, 1, 1),
            Owner ! {connected, N},
            {ok, {connection, N}}
        end}).

wait_waiters(Pool, Count) ->
    case adk_mcp_pool:status(Pool) of
        {ok, #{waiting := Count}} -> ok;
        _ -> timer:sleep(5), wait_waiters(Pool, Count)
    end.
