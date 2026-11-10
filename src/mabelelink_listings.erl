-module(mabelelink_listings).
-behaviour(gen_server).

%% In-memory listing and reservation service. Persistence and authentication
%% are intentionally left for the next MVP increment.
-export([start_link/0, create/1, list/0, get/1, reserve/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE).

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

create(Attributes) when is_map(Attributes) ->
    gen_server:call(?SERVER, {create, Attributes}).

list() ->
    gen_server:call(?SERVER, list).

get(Id) ->
    gen_server:call(?SERVER, {get, Id}).

reserve(Id, Quantity) when is_number(Quantity), Quantity > 0 ->
    gen_server:call(?SERVER, {reserve, Id, Quantity});
reserve(_Id, _Quantity) ->
    {error, invalid_quantity}.

init([]) ->
    {ok, #{listings => #{}, next_id => 1}}.

handle_call({create, Attributes}, _From, State) ->
    case validate_listing(Attributes) of
        {ok, Listing} ->
            Id = maps:get(next_id, State),
            Stored = Listing#{id => Id, available_quantity => maps:get(quantity, Listing)},
            Listings = maps:put(Id, Stored, maps:get(listings, State)),
            {reply, {ok, Stored}, State#{listings => Listings, next_id => Id + 1}};
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
handle_call({reserve, Id, Quantity}, _From, State) ->
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
                    Updated = Listing#{available_quantity => Available - Quantity},
                    {reply, {ok, #{listing => Updated, reserved_quantity => Quantity}},
                     State#{listings => maps:put(Id, Updated, Listings)}}
            end
    end;
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_request}, State}.

handle_cast(_Message, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVersion, State, _Extra) ->
    {ok, State}.

validate_listing(Attributes) ->
    Required = [farmer_name, crop, quantity, unit, location],
    Missing = [Key || Key <- Required, not maps:is_key(Key, Attributes)],
    case Missing of
        [] ->
            Quantity = maps:get(quantity, Attributes),
            case is_number(Quantity) andalso Quantity > 0 of
                true ->
                    {ok, maps:with(Required ++ [notes], Attributes)};
                false ->
                    {error, invalid_quantity}
            end;
        _ ->
            {error, {missing_fields, Missing}}
    end.
