-module(mabelelink_listings).
-behaviour(gen_server).

%% Single-node MVP store. The complete business state is kept in one DETS
%% object and synced after each update. DETS is not a transactional database;
%% use PostgreSQL before real multi-user field deployment.
-export([start_link/0, create/1, list/0, get/1,
         reserve/2, reserve/3, reserve/4,
         reservations/0, audit_events/0,
         confirm_reservation/1, cancel_reservation/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(STATE_KEY, mabelelink_state).

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

create(Attributes) when is_map(Attributes) ->
    gen_server:call(?SERVER, {create, Attributes}).

list() ->
    gen_server:call(?SERVER, list).

get(Id) ->
    gen_server:call(?SERVER, {get, Id}).

reserve(Id, Quantity) ->
    reserve(Id, Quantity, #{}, undefined).

reserve(Id, Quantity, Buyer) when is_map(Buyer) ->
    reserve(Id, Quantity, Buyer, undefined).

reserve(Id, Quantity, Buyer, IdempotencyKey)
  when is_number(Quantity), Quantity > 0, is_map(Buyer) ->
    gen_server:call(?SERVER, {reserve, Id, Quantity, Buyer, IdempotencyKey});
reserve(_Id, _Quantity, _Buyer, _IdempotencyKey) ->
    {error, invalid_quantity}.

reservations() ->
    gen_server:call(?SERVER, reservations).

audit_events() ->
    gen_server:call(?SERVER, audit_events).

confirm_reservation(Id) ->
    gen_server:call(?SERVER, {transition_reservation, Id, confirmed}).

cancel_reservation(Id) ->
    gen_server:call(?SERVER, {transition_reservation, Id, cancelled}).

init([]) ->
    Path = data_file(),
    ok = filelib:ensure_dir(Path),
    case dets:open_file(?SERVER, [{file, Path}, {type, set}]) of
        {ok, ?SERVER} ->
            case dets:lookup(?SERVER, ?STATE_KEY) of
                [{?STATE_KEY, StoredState}] -> {ok, StoredState};
                [] -> migrate_legacy_data()
            end;
        {error, Reason} ->
            {stop, {storage_open_failed, Reason}}
    end.

migrate_legacy_data() ->
    LegacyListings = maps:from_list(
        [{Id, Listing} || {Id, Listing} <- dets:match_object(?SERVER, {'_', '_'}),
                          is_integer(Id), is_map(Listing)]),
    State = initial_state(LegacyListings),
    case persist_state(State) of
        ok -> {ok, State};
        {error, Reason} -> {stop, {storage_migration_failed, Reason}}
    end.

initial_state(Listings) ->
    NextListingId = case maps:keys(Listings) of
                        [] -> 1;
                        Ids -> lists:max(Ids) + 1
                    end,
    #{listings => Listings,
      reservations => #{},
      idempotency => #{},
      events => [],
      next_listing_id => NextListingId,
      next_reservation_id => 1,
      next_event_id => 1}.

handle_call({create, Attributes}, _From, State) ->
    case validate_listing(Attributes) of
        {ok, Listing} ->
            Id = maps:get(next_listing_id, State),
            Timestamp = now_seconds(),
            Stored = Listing#{id => Id,
                              status => active,
                              created_at => Timestamp,
                              available_quantity => maps:get(quantity, Listing)},
            Listings = maps:put(Id, Stored, maps:get(listings, State)),
            NewState0 = State#{listings => Listings, next_listing_id => Id + 1},
            NewState = add_event(NewState0, listing_created,
                                 #{listing_id => Id}),
            commit(NewState, {ok, Stored}, State);
        Error ->
            {reply, Error, State}
    end;
handle_call(list, _From, State) ->
    Listings = maps:values(maps:get(listings, State)),
    {reply, {ok, Listings}, State};
handle_call({get, Id}, _From, State) ->
    Reply = case maps:find(Id, maps:get(listings, State)) of
                {ok, Listing} -> {ok, Listing};
                error -> {error, not_found}
            end,
    {reply, Reply, State};
handle_call({reserve, Id, Quantity, Buyer, IdempotencyKey}, _From, State) ->
    reserve_listing(Id, Quantity, Buyer, IdempotencyKey, State);
handle_call(reservations, _From, State) ->
    Values = maps:values(maps:get(reservations, State)),
    Ordered = lists:sort(fun(A, B) -> maps:get(id, A) < maps:get(id, B) end, Values),
    {reply, {ok, Ordered}, State};
handle_call(audit_events, _From, State) ->
    {reply, {ok, lists:reverse(maps:get(events, State))}, State};
handle_call({transition_reservation, Id, TargetStatus}, _From, State) ->
    transition_reservation(Id, TargetStatus, State);
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_request}, State}.

reserve_listing(Id, Quantity, Buyer, IdempotencyKey, State) ->
    Idempotency = maps:get(idempotency, State),
    Request = reservation_request(Id, Quantity, Buyer),
    case find_idempotent_reservation(IdempotencyKey, Request, Idempotency,
                                     maps:get(reservations, State)) of
        {ok, Existing} ->
            {reply, {ok, Existing#{duplicate => true}}, State};
        conflict ->
            {reply, {error, idempotency_conflict}, State};
        not_found ->
            create_reservation(Id, Quantity, Buyer, IdempotencyKey, Request, State)
    end.

find_idempotent_reservation(undefined, _Request, _Idempotency, _Reservations) -> not_found;
find_idempotent_reservation(<<>>, _Request, _Idempotency, _Reservations) -> not_found;
find_idempotent_reservation(Key, Request, Idempotency, Reservations) when is_binary(Key) ->
    case maps:find({reservation, Key}, Idempotency) of
        {ok, #{reservation_id := Id, request := Request}} ->
            {ok, maps:get(Id, Reservations)};
        {ok, _DifferentRequest} -> conflict;
        error -> not_found
    end;
find_idempotent_reservation(_Key, _Request, _Idempotency, _Reservations) -> not_found.

create_reservation(Id, Quantity, Buyer, IdempotencyKey, Request, State) ->
    Listings = maps:get(listings, State),
    case maps:find(Id, Listings) of
        error ->
            {reply, {error, not_found}, State};
        {ok, Listing} ->
            Available = maps:get(available_quantity, Listing),
            if
                Quantity > Available ->
                    {reply, {error, insufficient_quantity}, State};
                true ->
                    ReservationId = maps:get(next_reservation_id, State),
                    Timestamp = now_seconds(),
                    Reservation = maps:merge(
                        #{id => ReservationId,
                          listing_id => Id,
                          quantity => Quantity,
                          status => pending,
                          created_at => Timestamp,
                          updated_at => Timestamp},
                        maps:with([buyer_name, buyer_contact], Buyer)),
                    UpdatedListing = Listing#{available_quantity => Available - Quantity},
                    UpdatedListings = maps:put(Id, UpdatedListing, Listings),
                    Reservations = maps:put(ReservationId, Reservation,
                                            maps:get(reservations, State)),
                    Idempotency0 = maps:get(idempotency, State),
                    Idempotency1 = case IdempotencyKey of
                                       Key when is_binary(Key), byte_size(Key) > 0 ->
                                           maps:put({reservation, Key},
                                               #{reservation_id => ReservationId,
                                                 request => Request}, Idempotency0);
                                       _ -> Idempotency0
                                   end,
                    NewState0 = State#{listings => UpdatedListings,
                                       reservations => Reservations,
                                       idempotency => Idempotency1,
                                       next_reservation_id => ReservationId + 1},
                    NewState = add_event(NewState0, reservation_requested,
                                         #{reservation_id => ReservationId,
                                           listing_id => Id,
                                           quantity => Quantity}),
                    commit(NewState, {ok, Reservation}, State)
            end
    end.

reservation_request(Id, Quantity, Buyer) ->
    #{listing_id => Id,
      quantity => Quantity,
      buyer_name => maps:get(buyer_name, Buyer, <<>>),
      buyer_contact => maps:get(buyer_contact, Buyer, <<>>)}.

transition_reservation(Id, TargetStatus, State) ->
    Reservations = maps:get(reservations, State),
    case maps:find(Id, Reservations) of
        error ->
            {reply, {error, not_found}, State};
        {ok, #{status := TargetStatus} = Existing} ->
            {reply, {ok, Existing}, State};
        {ok, #{status := pending} = Existing} ->
            Reservation = Existing#{status => TargetStatus,
                                    updated_at => now_seconds()},
            Reservations1 = maps:put(Id, Reservation, Reservations),
            NewState0 = State#{reservations => Reservations1},
            NewState1 = case TargetStatus of
                cancelled -> restore_quantity(Reservation, NewState0);
                confirmed -> NewState0
            end,
            NewState = add_event(NewState1, reservation_status_changed,
                                 #{reservation_id => Id, status => TargetStatus}),
            commit(NewState, {ok, Reservation}, State);
        {ok, _Existing} ->
            {reply, {error, invalid_transition}, State}
    end.

restore_quantity(Reservation, State) ->
    ListingId = maps:get(listing_id, Reservation),
    Listings = maps:get(listings, State),
    Listing = maps:get(ListingId, Listings),
    Quantity = maps:get(quantity, Reservation),
    State#{listings => maps:put(ListingId,
                                Listing#{available_quantity =>
                                             maps:get(available_quantity, Listing) + Quantity},
                                Listings)}.

add_event(State, Type, Details) ->
    Id = maps:get(next_event_id, State),
    Event = #{id => Id, type => Type, actor => operator,
              timestamp => now_seconds(), details => Details},
    State#{events => [Event | maps:get(events, State)], next_event_id => Id + 1}.

commit(NewState, Reply, OldState) ->
    case persist_state(NewState) of
        ok -> {reply, Reply, NewState};
        {error, Reason} ->
            {stop, {storage_write_failed, Reason},
             {error, {storage_write_failed, Reason}}, OldState}
    end.

handle_cast(_Message, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    dets:close(?SERVER),
    ok.

code_change(_OldVersion, State, _Extra) ->
    {ok, State}.

validate_listing(Attributes) ->
    Required = [farmer_name, crop, quantity, unit, location],
    Missing = [Key || Key <- Required, not maps:is_key(Key, Attributes)],
    case Missing of
        [] ->
            Quantity = maps:get(quantity, Attributes),
            TextValues = [maps:get(Key, Attributes) || Key <-
                          [farmer_name, crop, unit, location]],
            NotesValid = case maps:find(notes, Attributes) of
                             {ok, Notes} -> valid_text(Notes, 500);
                             error -> true
                         end,
            case is_number(Quantity) andalso Quantity > 0 andalso
                 lists:all(fun(Value) -> valid_text(Value, 120) end, TextValues) andalso
                 NotesValid of
                true -> {ok, maps:with(Required ++ [notes], Attributes)};
                false -> {error, invalid_listing}
            end;
        _ ->
            {error, {missing_fields, Missing}}
    end.

valid_text(Value, MaxBytes) when is_binary(Value) ->
    byte_size(Value) > 0 andalso byte_size(Value) =< MaxBytes;
valid_text(Value, _MaxBytes) when is_atom(Value) ->
    Value =/= undefined andalso Value =/= null;
valid_text(_Value, _MaxBytes) ->
    false.

data_file() ->
    case application:get_env(mabelelink, data_file) of
        {ok, Path} -> Path;
        undefined -> filename:join(["data", "mabelelink.dets"])
    end.

persist_state(State) ->
    case dets:insert(?SERVER, {?STATE_KEY, State}) of
        ok -> dets:sync(?SERVER);
        Error -> Error
    end.

now_seconds() ->
    erlang:system_time(second).
