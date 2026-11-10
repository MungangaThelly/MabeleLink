-module(mabelelink_http_handler).
-behaviour(cowboy_handler).

-export([init/2]).

-define(MAX_BODY_BYTES, 16384).

init(Req, health) ->
    respond(200, #{status => <<"ok">>}, Req);
init(Req, listings) ->
    authenticated(Req, fun(AuthorizedReq) ->
        handle_listings(cowboy_req:method(AuthorizedReq), AuthorizedReq)
    end);
init(Req, listing) ->
    authenticated(Req, fun(AuthorizedReq) ->
        handle_listing(cowboy_req:method(AuthorizedReq),
                       cowboy_req:binding(id, AuthorizedReq), AuthorizedReq)
    end);
init(Req, reservation) ->
    authenticated(Req, fun(AuthorizedReq) ->
        handle_reservation(cowboy_req:method(AuthorizedReq),
                           cowboy_req:binding(id, AuthorizedReq), AuthorizedReq)
    end);
init(Req, reservations) ->
    authenticated(Req, fun(AuthorizedReq) ->
        handle_reservations(cowboy_req:method(AuthorizedReq), AuthorizedReq)
    end);
init(Req, {reservation_action, Action}) ->
    authenticated(Req, fun(AuthorizedReq) ->
        handle_reservation_action(cowboy_req:method(AuthorizedReq), Action,
                                  cowboy_req:binding(id, AuthorizedReq), AuthorizedReq)
    end);
init(Req, audit_events) ->
    authenticated(Req, fun(AuthorizedReq) ->
        handle_audit_events(cowboy_req:method(AuthorizedReq), AuthorizedReq)
    end).

authenticated(Req, Action) ->
    case mabelelink_auth:check(Req) of
        ok -> Action(Req);
        {error, unconfigured} ->
            respond(503, #{error => <<"api_token_not_configured">>}, Req);
        {error, unauthorized} ->
            Req1 = cowboy_req:reply(401,
                #{<<"content-type">> => <<"application/json; charset=utf-8">>,
                  <<"www-authenticate">> => <<"Bearer">>},
                jsx:encode(#{error => <<"unauthorized">>}), Req),
            {ok, Req1, undefined}
    end.

handle_listings(<<"GET">>, Req) ->
    {ok, Listings} = mabelelink_listings:list(),
    respond(200, Listings, Req);
handle_listings(<<"POST">>, Req) ->
    with_json_body(Req, fun(Body, Req1) ->
        Attributes = listing_attributes(Body),
        case mabelelink_listings:create(Attributes) of
            {ok, Listing} -> respond(201, Listing, Req1);
            {error, {missing_fields, Missing}} ->
                respond(400, #{error => <<"missing_fields">>, fields => Missing}, Req1);
            {error, invalid_listing} ->
                respond(400, #{error => <<"invalid_listing">>}, Req1);
            {error, {storage_write_failed, _}} ->
                respond(500, #{error => <<"storage_failure">>}, Req1)
        end
    end);
handle_listings(_Method, Req) ->
    respond(405, #{error => <<"method_not_allowed">>}, Req).

handle_listing(<<"GET">>, IdBin, Req) ->
    case parse_id(IdBin) of
        {ok, Id} ->
            case mabelelink_listings:get(Id) of
                {ok, Listing} -> respond(200, Listing, Req);
                {error, not_found} -> respond(404, #{error => <<"not_found">>}, Req)
            end;
        error -> respond(400, #{error => <<"invalid_id">>}, Req)
    end;
handle_listing(_Method, _IdBin, Req) ->
    respond(405, #{error => <<"method_not_allowed">>}, Req).

handle_reservation(<<"POST">>, IdBin, Req) ->
    case parse_id(IdBin) of
        {ok, Id} ->
            with_json_body(Req, fun(Body, Req1) ->
                Quantity = maps:get(<<"quantity">>, Body, undefined),
                BuyerName = maps:get(<<"buyer_name">>, Body, undefined),
                Contact = maps:get(<<"buyer_contact">>, Body, undefined),
                case valid_buyer(BuyerName, Contact) andalso
                     is_number(Quantity) andalso Quantity > 0 of
                    true ->
                        Buyer = #{buyer_name => BuyerName,
                                  buyer_contact => optional_binary(Contact)},
                        RequestKey = cowboy_req:header(<<"idempotency-key">>, Req1),
                        case mabelelink_listings:reserve(Id, Quantity, Buyer, RequestKey) of
                            {ok, Reservation} ->
                                respond(201, Reservation, Req1);
                            {error, not_found} ->
                                respond(404, #{error => <<"not_found">>}, Req1);
                            {error, insufficient_quantity} ->
                                respond(409, #{error => <<"insufficient_quantity">>}, Req1);
                            {error, idempotency_conflict} ->
                                respond(409, #{error => <<"idempotency_conflict">>}, Req1);
                            {error, {storage_write_failed, _}} ->
                                respond(500, #{error => <<"storage_failure">>}, Req1)
                        end;
                    false ->
                        respond(400, #{error => <<"invalid_reservation">>}, Req1)
                end
            end);
        error -> respond(400, #{error => <<"invalid_id">>}, Req)
    end;
handle_reservation(_Method, _IdBin, Req) ->
    respond(405, #{error => <<"method_not_allowed">>}, Req).

handle_reservations(<<"GET">>, Req) ->
    {ok, Reservations} = mabelelink_listings:reservations(),
    respond(200, Reservations, Req);
handle_reservations(_Method, Req) ->
    respond(405, #{error => <<"method_not_allowed">>}, Req).

handle_reservation_action(<<"POST">>, Action, IdBin, Req) ->
    case parse_id(IdBin) of
        {ok, Id} ->
            Result = case Action of
                         confirm -> mabelelink_listings:confirm_reservation(Id);
                         cancel -> mabelelink_listings:cancel_reservation(Id)
                     end,
            case Result of
                {ok, Reservation} -> respond(200, Reservation, Req);
                {error, not_found} -> respond(404, #{error => <<"not_found">>}, Req);
                {error, invalid_transition} ->
                    respond(409, #{error => <<"invalid_transition">>}, Req);
                {error, {storage_write_failed, _}} ->
                    respond(500, #{error => <<"storage_failure">>}, Req)
            end;
        error -> respond(400, #{error => <<"invalid_id">>}, Req)
    end;
handle_reservation_action(_Method, _Action, _IdBin, Req) ->
    respond(405, #{error => <<"method_not_allowed">>}, Req).

handle_audit_events(<<"GET">>, Req) ->
    {ok, Events} = mabelelink_listings:audit_events(),
    respond(200, Events, Req);
handle_audit_events(_Method, Req) ->
    respond(405, #{error => <<"method_not_allowed">>}, Req).

with_json_body(Req, Fun) ->
    case cowboy_req:read_body(Req, #{length => ?MAX_BODY_BYTES, period => 5000}) of
        {ok, Body, Req1} ->
            try jsx:decode(Body, [return_maps]) of
                Decoded when is_map(Decoded) -> Fun(Decoded, Req1);
                _ -> respond(400, #{error => <<"expected_json_object">>}, Req1)
            catch
                _:_ -> respond(400, #{error => <<"invalid_json">>}, Req1)
            end;
        {more, _PartialBody, Req1} ->
            respond(413, #{error => <<"request_too_large">>}, Req1)
    end.

listing_attributes(Body) ->
    Allowed = [farmer_name, crop, quantity, unit, location, notes],
    lists:foldl(fun(Key, Acc) ->
        JsonKey = atom_to_binary(Key, utf8),
        case maps:find(JsonKey, Body) of
            {ok, Value} -> maps:put(Key, Value, Acc);
            error -> Acc
        end
    end, #{}, Allowed).

valid_buyer(Name, Contact) ->
    is_binary(Name) andalso byte_size(Name) > 0 andalso byte_size(Name) =< 120 andalso
    (Contact =:= undefined orelse Contact =:= <<>> orelse
     (is_binary(Contact) andalso byte_size(Contact) > 0 andalso byte_size(Contact) =< 80)).

optional_binary(undefined) -> <<>>;
optional_binary(Value) -> Value.

parse_id(undefined) -> error;
parse_id(IdBin) ->
    try binary_to_integer(IdBin) of
        Id when Id > 0 -> {ok, Id};
        _ -> error
    catch
        _:_ -> error
    end.

respond(Status, Value, Req) ->
    Req1 = cowboy_req:reply(Status,
        #{<<"content-type">> => <<"application/json; charset=utf-8">>},
        jsx:encode(json_safe(Value)), Req),
    {ok, Req1, undefined}.

json_safe(Value) when is_map(Value) ->
    maps:from_list([{json_key(Key), json_safe(Item)} || {Key, Item} <- maps:to_list(Value)]);
json_safe(Value) when is_list(Value) ->
    [json_safe(Item) || Item <- Value];
json_safe(true) -> true;
json_safe(false) -> false;
json_safe(null) -> null;
json_safe(Value) when is_atom(Value) ->
    atom_to_binary(Value, utf8);
json_safe(Value) ->
    Value.

json_key(Key) when is_atom(Key) -> atom_to_binary(Key, utf8);
json_key(Key) when is_binary(Key) -> Key.
