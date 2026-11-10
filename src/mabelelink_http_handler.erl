-module(mabelelink_http_handler).
-behaviour(cowboy_handler).

-export([init/2]).

-define(MAX_BODY_BYTES, 16384).

init(Req, health) ->
    respond(200, #{status => <<"ok">>}, Req);
init(Req, listings) ->
    handle_listings(cowboy_req:method(Req), Req);
init(Req, listing) ->
    handle_listing(cowboy_req:method(Req), cowboy_req:binding(id, Req), Req);
init(Req, reservation) ->
    handle_reservation(cowboy_req:method(Req), cowboy_req:binding(id, Req), Req).

handle_listings(<<"GET">>, Req) ->
    {ok, Listings} = mabelelink_listings:list(),
    respond(200, Listings, Req);
handle_listings(<<"POST">>, Req) ->
    with_json_body(Req, fun(Body, Req1) ->
        case listing_attributes(Body) of
            {ok, Attributes} ->
                case mabelelink_listings:create(Attributes) of
                    {ok, Listing} -> respond(201, Listing, Req1);
                    {error, {missing_fields, Missing}} ->
                        respond(400, #{error => <<"missing_fields">>, fields => Missing}, Req1);
                    {error, invalid_quantity} ->
                        respond(400, #{error => <<"invalid_quantity">>}, Req1);
                    {error, {storage_write_failed, _}} ->
                        respond(500, #{error => <<"storage_failure">>}, Req1)
                end;
            error -> respond(400, #{error => <<"invalid_listing">>}, Req1)
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
                case maps:get(<<"quantity">>, Body, undefined) of
                    Quantity when is_number(Quantity), Quantity > 0 ->
                        case mabelelink_listings:reserve(Id, Quantity) of
                            {ok, Reservation} -> respond(201, Reservation, Req1);
                            {error, not_found} ->
                                respond(404, #{error => <<"not_found">>}, Req1);
                            {error, insufficient_quantity} ->
                                respond(409, #{error => <<"insufficient_quantity">>}, Req1);
                            {error, {storage_write_failed, _}} ->
                                respond(500, #{error => <<"storage_failure">>}, Req1)
                        end;
                    _ -> respond(400, #{error => <<"invalid_quantity">>}, Req1)
                end
            end);
        error -> respond(400, #{error => <<"invalid_id">>}, Req)
    end;
handle_reservation(_Method, _IdBin, Req) ->
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
    Attributes = lists:foldl(fun(Key, Acc) ->
        JsonKey = atom_to_binary(Key, utf8),
        case maps:find(JsonKey, Body) of
            {ok, Value} -> maps:put(Key, Value, Acc);
            error -> Acc
        end
    end, #{}, Allowed),
    {ok, Attributes}.

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
