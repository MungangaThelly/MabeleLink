-module(mabelelink_listings_tests).

-include_lib("eunit/include/eunit.hrl").

listings_test_() ->
    {foreach,
     fun setup/0,
     fun cleanup/1,
     [fun(Path) -> ?_test(create_and_fetch(Path)) end,
      fun(Path) -> ?_test(reject_missing_fields(Path)) end,
      fun(Path) -> ?_test(reject_invalid_quantity(Path)) end,
      fun(Path) -> ?_test(reserve_available_quantity(Path)) end,
      fun(Path) -> ?_test(reject_oversubscription(Path)) end,
      fun(Path) -> ?_test(persist_across_restart(Path)) end,
      fun(Path) -> ?_test(serialize_concurrent_reservations(Path)) end]}.

setup() ->
    Path = filename:join(["_build", "test",
                          "mabelelink-listings-" ++
                              integer_to_list(erlang:unique_integer([positive])) ++
                              ".dets"]),
    ok = application:set_env(mabelelink, data_file, Path),
    {ok, _Pid} = mabelelink_listings:start_link(),
    Path.

cleanup(Path) ->
    case whereis(mabelelink_listings) of
        Pid when is_pid(Pid) ->
            try gen_server:stop(Pid) catch _:_ -> ok end;
        undefined -> ok
    end,
    _ = application:unset_env(mabelelink, data_file),
    _ = file:delete(Path),
    ok.

create_and_fetch(_Path) ->
    {ok, Listing} = mabelelink_listings:create(valid_listing()),
    Id = maps:get(id, Listing),
    ?assertEqual(500, maps:get(available_quantity, Listing)),
    ?assertEqual({ok, Listing}, mabelelink_listings:get(Id)),
    {ok, [Listed]} = mabelelink_listings:list(),
    ?assertEqual(Listing, Listed).

reject_missing_fields(_Path) ->
    ?assertEqual({error, {missing_fields, [location]}},
                 mabelelink_listings:create(maps:remove(location, valid_listing()))).

reject_invalid_quantity(_Path) ->
    ?assertEqual({error, invalid_quantity},
                 mabelelink_listings:create((valid_listing())#{quantity => 0})),
    ?assertEqual({error, invalid_quantity}, mabelelink_listings:reserve(1, 0)).

reserve_available_quantity(_Path) ->
    {ok, Listing} = mabelelink_listings:create(valid_listing()),
    Id = maps:get(id, Listing),
    {ok, Reservation} = mabelelink_listings:reserve(Id, 125),
    ?assertEqual(125, maps:get(reserved_quantity, Reservation)),
    ?assertEqual(375, maps:get(available_quantity, maps:get(listing, Reservation))).

reject_oversubscription(_Path) ->
    {ok, Listing} = mabelelink_listings:create(valid_listing()),
    Id = maps:get(id, Listing),
    ?assertEqual({error, insufficient_quantity},
                 mabelelink_listings:reserve(Id, 501)),
    {ok, Unchanged} = mabelelink_listings:get(Id),
    ?assertEqual(500, maps:get(available_quantity, Unchanged)).

persist_across_restart(Path) ->
    {ok, Listing} = mabelelink_listings:create(valid_listing()),
    Id = maps:get(id, Listing),
    ok = gen_server:stop(mabelelink_listings),
    {ok, _Pid} = mabelelink_listings:start_link(),
    ?assertEqual({ok, Listing}, mabelelink_listings:get(Id)),
    {ok, Next} = mabelelink_listings:create(valid_listing()),
    ?assertEqual(Id + 1, maps:get(id, Next)),
    ?assert(filelib:is_file(Path)).

serialize_concurrent_reservations(_Path) ->
    {ok, Listing} = mabelelink_listings:create((valid_listing())#{quantity => 10}),
    Id = maps:get(id, Listing),
    Parent = self(),
    [spawn(fun() -> Parent ! {reservation, mabelelink_listings:reserve(Id, 1)} end)
     || _ <- lists:seq(1, 20)],
    {Succeeded, Rejected} = collect_reservations(20, 0, 0),
    ?assertEqual(10, Succeeded),
    ?assertEqual(10, Rejected),
    {ok, Updated} = mabelelink_listings:get(Id),
    ?assertEqual(0, maps:get(available_quantity, Updated)).

collect_reservations(0, Succeeded, Rejected) ->
    {Succeeded, Rejected};
collect_reservations(Remaining, Succeeded, Rejected) ->
    receive
        {reservation, {ok, _}} ->
            collect_reservations(Remaining - 1, Succeeded + 1, Rejected);
        {reservation, {error, insufficient_quantity}} ->
            collect_reservations(Remaining - 1, Succeeded, Rejected + 1)
    after 5000 ->
        error(reservation_timeout)
    end.

valid_listing() ->
    #{farmer_name => <<"Amina">>,
      crop => <<"cassava">>,
      quantity => 500,
      unit => <<"kg">>,
      location => <<"Kongo Central">>}.
