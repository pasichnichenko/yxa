%%%-------------------------------------------------------------------
%%% File    : outgoingproxy.erl
%%% Author  : Fredrik Thulin <ft@it.su.se>
%%% Descrip.: YXA application to manage client connections from your
%%%           user agents. Keeps TCP connections open virtually
%%%           forever, and implements draft-Outbound to helt clients
%%%           behind NATs etc.
%%%
%%% Created : 16 Mar 2005 by Fredrik Thulin <ft@it.su.se>
%%%-------------------------------------------------------------------
-module(outgoingproxy).

-behaviour(yxa_app).

%%--------------------------------------------------------------------
%%% Standard YXA SIP-application callback functions
%%--------------------------------------------------------------------
-export([
	 init/0,
	 request/2,
	 response/2,
	 terminate/1
	]).

%%--------------------------------------------------------------------
%% Include files
%%--------------------------------------------------------------------
-include("siprecords.hrl").
-include("sipsocket.hrl").

%%--------------------------------------------------------------------
%% Macros
%%--------------------------------------------------------------------
-define(SIPPIPE_TIMEOUT, 900).

%%====================================================================
%% Behaviour functions
%% Standard YXA SIP-application callback functions
%%====================================================================

%%--------------------------------------------------------------------
%% Function: init()
%% Descrip.: YXA applications must export an init/0 function.
%% Returns : [Tables, Mode, SupData]
%%           Tables  = list() of atom(), remote mnesia tables the YXA
%%                     startup sequence should make sure are available
%%           Mode    = stateful
%%           SupData = {append, SupSpec} |
%%                     none
%%           SupSpec = OTP supervisor child specification. Extra
%%                     processes this application want the
%%                     sipserver_sup to start and maintain.
%%--------------------------------------------------------------------
init() ->
    [[user, numbers, phone], stateful, none].

%%--------------------------------------------------------------------
%% Function: request(Request, YxaCtx)
%%           Request = request record()
%%           YxaCtx  = yxa_ctx record()
%% Descrip.: YXA applications must export a request/2 function.
%% Returns : Yet to be specified. Return 'ok' for now.
%%--------------------------------------------------------------------


%%
%% REGISTER
%%
request(#request{method = "REGISTER"} = Request, YxaCtx) when is_record(YxaCtx, yxa_ctx) ->
    THandler = YxaCtx#yxa_ctx.thandler,
    LogTag = transactionlayer:get_branchbase_from_handler(THandler),
    YxaCtx1 =
	YxaCtx#yxa_ctx{app_logtag = LogTag
		      },
    case siplocation:process_register_request(Request, YxaCtx1, outgoingproxy) of
	not_homedomain ->
	    case yxa_config:get_env(allow_foreign_registers) of
		{ok, true} ->
		    do_foreign_register(Request, YxaCtx1);
		{ok, false} ->
		    transactionlayer:send_response_handler(THandler, 403, "Domain not handled by this proxy")
	    end;
	_ ->
	    true
    end,
    ok;

%%
%% ACK
%%
request(#request{method = "ACK"} = Request, YxaCtx) when is_record(YxaCtx, yxa_ctx) ->
    transportlayer:stateless_proxy_ack("outgoingproxy", Request, YxaCtx),
    ok;

%%
%% Anything but REGISTER and ACK
%%
request(Request, YxaCtx) when is_record(Request, request), is_record(YxaCtx, yxa_ctx) ->
    do_request(Request, YxaCtx).

%% Note: All the RFC quotes in this function are from RFC3327 #5.2 (Procedures at Intermediate Proxies)
do_foreign_register(Request, YxaCtx) ->
    #request{uri    = URI,
	     header = Header
	    } = Request,

    %% We do Path (RFC3327) if the UA said it supports it, or if we are configured to always do Path
    %% for foreign registrations

    DoPath =
	case sipheader:is_supported("path", Header) of
	    true -> {ok, true};
	    false ->
		case yxa_config:get_env(always_do_path_for_foreign_registers) of
		    {ok, true} ->
			%% "Intermediate proxies SHOULD NOT add a Path header field to a request
			%% unless the UA has indicated support for this extension with a
			%% Supported header field value."
			logger:log(debug, "outgoingproxy: Notice: REGISTER request to foreign domain (~p), "
				   "using Path even though UA did not say it supports it", [URI#sipurl.host]),
			%% XXX Path to foreign domain SHOULD contain an identifier of the flow we received
			%% it on in the user-part of the Path header value (how are we otherwise to be able
			%% to map requests sent to the AOR in the foreign domain to the right flow?)
			true;
		    {ok, false} ->
			false
		end
	end,

    case DoPath of
	true ->
	    RRStr = siprequest:construct_record_route(URI#sipurl.proto),
	    NewHeader1 = keylist:prepend({"Path", [RRStr]}, Header),
	    NewHeader =
		case sipheader:is_required("path", NewHeader1) of
		    true ->
			NewHeader1;
		    false ->
			%% "If the UA has indicated support and
			%% the proxy requires the registrar to support the Path extension, then
			%% the proxy SHOULD insert a Requires header field value for this
			%% extension."
			%% We do require it, since the only point of using an outgoingproxy is that you
			%% must get all incoming requests through an existing network flow.
			keylist:append({"Require", ["path"]}, NewHeader1)
		end,
	    do_request(Request#request{header = NewHeader}, YxaCtx);
	false ->
	    %% "If the UA has not indicated support for the extension and
	    %% the proxy requires support for it in the registrar, the proxy SHOULD
	    %% reject the request with a 421 response indicating a requirement for
	    %% the extension."
	    THandler = YxaCtx#yxa_ctx.thandler,
	    transactionlayer:send_response_handler(THandler, 421, "Extension Required",
						  [{"Require", ["path"]}])
    end.


%%--------------------------------------------------------------------
%% Function: response(Response, YxaCtx)
%%           Request = response record()
%%           YxaCtx  = yxa_ctx record()
%% Descrip.: YXA applications must export a response/2 function.
%% Returns : Yet to be specified. Return 'ok' for now.
%%--------------------------------------------------------------------
response(Response, YxaCtx) when is_record(Response, response), is_record(YxaCtx, yxa_ctx) ->
    {Status, Reason} = {Response#response.status, Response#response.reason},
    logger:log(normal, "outgoingproxy: Response to ~s: '~p ~s', no matching transaction - proxying statelessly",
	       [YxaCtx#yxa_ctx.logstr, Status, Reason]),
    transportlayer:send_proxy_response(none, Response),
    ok.


%%--------------------------------------------------------------------
%% Function: terminate(Mode)
%%           Mode = atom(), shutdown | graceful | ...
%% Descrip.: YXA applications must export a terminate/1 function.
%% Returns : Yet to be specified. Return 'ok' for now.
%%--------------------------------------------------------------------
terminate(Mode) when is_atom(Mode) ->
    ok.


%%====================================================================
%% Internal functions
%%====================================================================

do_request(Request, YxaCtx) when is_record(Request, request), is_record(YxaCtx, yxa_ctx) ->
    #request{method = Method,
	     uri    = URI
	    } = Request,

    %% outgoingproxys need to add Record-Route header to make sure in-dialog requests go
    %% through the proxy.

    Location = route_request(Request),
    logger:log(debug, "outgoingproxy: Location: ~p", [Location]),
    THandler = YxaCtx#yxa_ctx.thandler,
    LogTag = transactionlayer:get_branchbase_from_handler(THandler),
    case Location of
	none ->
	    logger:log(normal, "~s: outgoingproxy: 403 Forbidden", [LogTag]),
	    transactionlayer:send_response_handler(THandler, 403, "Forbidden");

	{response, Status, Reason} ->
	    logger:log(normal, "~s: outgoingproxy: Response '~p ~s'", [LogTag, Status, Reason]),
	    transactionlayer:send_response_handler(THandler, Status, Reason);

	{forward, FwdURL} when is_record(FwdURL, sipurl), FwdURL#sipurl.user == none, FwdURL#sipurl.pass == none ->
	    logger:log(normal, "~s: outgoingproxy: Forward '~s ~s' to ~s",
		       [LogTag, Method, sipurl:print(URI), sipurl:print(FwdURL)]),
	    ApproxMsgSize = siprequest:get_approximate_msgsize(Request#request{uri=FwdURL}),
	    case sipdst:url_to_dstlist(FwdURL, ApproxMsgSize, URI) of
		{error, nxdomain} ->
		    logger:log(debug, "~s: outgoingproxy: Failed resolving FwdURL : NXDOMAIN"
			       " (responding '604 Does Not Exist Anywhere')", [LogTag]),
                    transactionlayer:send_response_handler(THandler, 604, "Does Not Exist Anywhere"),
                    error;
		{error, What} ->
		    logger:log(normal, "~s: outgoingproxy: Failed resolving FwdURL : ~p", [LogTag, What]),
                    transactionlayer:send_response_handler(THandler, 500, "Failed resolving forward destination"),
                    error;
		DstList when is_list(DstList) ->
		    proxy_request(THandler, Request, DstList)
	    end;

	{proxy, Loc} when is_record(Loc, sipurl) ->
	    logger:log(normal, "~s: outgoingproxy: Proxy ~s -> ~s", [LogTag, Method, sipurl:print(Loc)]),
	    proxy_request(THandler, Request, Loc);

	{proxy, [#sipdst{socket = Socket}] = DstList} when Socket /= undefined ->
	    logger:log(normal, "~s: outgoingproxy: Proxy ~s ~s -> socket ~p",
		       [LogTag, Method, sipurl:print(URI), Socket#sipsocket.id]),
	    proxy_request(THandler, Request, DstList);

	{proxy, {with_path, Path}} when is_list(Path) ->
	    %% RFC3327
	    PathStr =
		case Path of
		    [H]     -> io_lib:format("~s", [H]);
		    [H | _] -> io_lib:format("~s, ...", [H])
		end,

	    logger:log(normal, "~s: outgoingproxy: Proxy ~s ~s -> Path: ~s",
		       [LogTag, Method, sipurl:print(URI), PathStr]),
	    NewHeader = keylist:prepend({"Route", Path}, Request#request.header),
	    NewRequest = Request#request{header = NewHeader},
	    proxy_request(THandler, NewRequest, route);

	{relay, Loc} ->
	    YxaCtx1 =
		YxaCtx#yxa_ctx{app_logtag = LogTag
			      },
	    relay_request(Request, Loc, YxaCtx1);

	me ->
	    request_to_me(THandler, Request, LogTag);

	_ ->
	    logger:log(error, "~s: outgoingproxy: Invalid Location ~p", [LogTag, Location]),
	    transactionlayer:send_response_handler(THandler, 500, "Server Internal Error")
    end.

%%--------------------------------------------------------------------
%% Function: route_request(Request)
%%           Request = request record()
%% Descrip.:
%% Returns : {error, Status}            |
%%           {response, Status, Reason} |
%%           {proxy, Location}          |
%%           {relay, Location}          |
%%           {forward, Location}        |
%%           me                         |
%%           none
%%--------------------------------------------------------------------
route_request(Request) when is_record(Request, request) ->
    route_request_check_gruu(Request).

route_request_check_gruu(Request) when is_record(Request, request) ->
    URI = Request#request.uri,
    case gruu:is_gruu_url(URI) of
	{true, GRUU} ->
	    case local:lookupuser_gruu(URI, GRUU) of
		{ok, User, {proxy, {with_path, Path}}, _Contact} ->
		    logger:log(debug, "outgoingproxy: Request destined for GRUU (user ~p), using Path.",
			       [User, Path]),
		    {proxy, {with_path, Path}};
		{ok, _User, GRUU_Res} when is_tuple(GRUU_Res) ->
		    GRUU_Res
	    end;
	false ->
	    route_request_check_route(Request)
    end.

%% Check if request has a Route header. If it does, we must decide wether we should relay or
%% proxy the request. We proxy (meaning without authentication) if the Request-URI or the last Route
%% header resolves to the registered location of one of our users.
route_request_check_route(Request) when is_record(Request, request) ->
    case keylist:fetch('route', Request#request.header) of
	[] ->
	    route_request_check_host(Request);
	Route ->
	    %% Request has Route header, allow if Request-URI is one of our users registered location
	    URI = Request#request.uri,
	    {ok, URI_Locations} = local:get_locations_with_contact(URI),
	    route_request_check_route2(Request#request.method, URI, URI_Locations, Route)
    end.

route_request_check_route2(_Method, URI, [#siplocationdb_e{sipuser = SIPuser} | _] = LocL, _Route) ->
    logger:log(debug, "outgoingproxy: Request destination ~p is a registered contact of user ~p - "
	       "proxying (~p location(s))", [sipurl:print(URI), SIPuser, length(LocL)]),
    route_request_to_user_contact(LocL);

route_request_check_route2("BYE", _URI, [], _Route) ->
    %% BYE and ACK can't be challenged, but ACKs get special treatment in request/3
    logger:log(debug, "outgoingproxy: Proxy BYE with Route header (without authentication)"),
    {proxy, route};

route_request_check_route2(Method, _URI, [], Route) ->
    %% Check if the last element in the Route list resolves to one of our users locations
    [LastRoute] = contact:parse([ hd(lists:reverse(Route)) ]),
    case local:get_locations_with_contact( sipurl:parse(LastRoute#contact.urlstr) ) of
	{ok, []} ->
	    logger:log(debug, "outgoingproxy: Relay ~s with Route header", [Method]),
	    {relay, route};
	{ok, [#siplocationdb_e{sipuser = SIPuser} | _] = Locations} ->
	    logger:log(debug, "outgoingproxy: Requests last route ~p is a registered contact of user ~p - "
		       "proxying (~p location(s))", [LastRoute#contact.urlstr, SIPuser, length(Locations)]),
	    route_request_to_user_contact(Locations)
    end.

route_request_check_host(Request) when is_record(Request, request) ->
    case local:is_request_to_this_proxy(Request) of
	true ->
	    route_request_host_is_this_proxy(Request);
	false ->
	    URI = Request#request.uri,
	    case local:get_locations_with_contact(URI) of
		{ok, []} ->
		    case yxa_config:get_env(sipproxy) of
			{ok, DefaultProxy} when is_record(DefaultProxy, sipurl) ->
			    {forward, DefaultProxy};
			none ->
			    none
		    end;
		{ok, [#siplocationdb_e{sipuser = SIPuser} | _] = Locations} ->
		    logger:log(debug, "outgoingproxy: Request destination ~p is a registered "
			       "contact of user ~p - proxying (~p location(s))", [URI, SIPuser, length(Locations)]),
		    route_request_to_user_contact(Locations)
	    end
    end.

route_request_to_user_contact(Locations) ->
    [First | _] = Sorted = siplocation:sort_most_recent_first(Locations),
    ThisNode = node(),
    case outbound_get_best_local(ThisNode, Sorted) of
	none ->
	    %% No Outbound registration found
	    {proxy, siplocation:to_url(First)};
	nomatch ->
	    %% Outbound registration found, but none with this node (or all inactive)
	    {response, 410, "Gone (used Outbound)"};
        {ok, Loc, SipSocket, LDB_SocketId} when is_record(LDB_SocketId, locationdb_socketid) ->
	    #locationdb_socketid{id    = SocketId,
				 proto = Proto,
				 addr  = Addr,
				 port  = Port
				} = LDB_SocketId,
	    %% XXX debug level?
	    logger:log(normal, "outgoingproxy: Using Outbound to send request to flow ~p (~p:~s:~p)",
		       [SocketId, Proto, Addr, Port]),
	    DstList =
		[#sipdst{uri	= siplocation:to_url(Loc),
			 socket	= SipSocket,
			 proto  = Proto,
			 addr   = Addr,
			 port   = Port
			}
		],
	    {proxy, DstList}
    end.

%% part of route_request_to_user_contact, find out if the local user has an
%% Outbound flow to this proxy
outbound_get_best_local(ThisNode, Sorted) ->
    outbound_get_best_local2(ThisNode, Sorted, false).

outbound_get_best_local2(LocalNode, [H | T], SomeOutbound) when is_atom(LocalNode), is_record(H, siplocationdb_e) ->
    case lists:keysearch(socket_id, 1, H#siplocationdb_e.flags) of
	{value, {socket_id, #locationdb_socketid{node = LocalNode, id = SocketId} = This}} ->
	    %% We have a stored socket_id, meaning the client did Outbound. We must now
	    %% check if that socket is still available.
	    case sipsocket:get_specific_socket(SocketId) of
		{error, _Reason} ->
		    %% keep looking
		    outbound_get_best_local2(LocalNode, T, true);
		SipSocket ->
		    {ok, H, SipSocket, This}
	    end;
	{value, {socket_id, #locationdb_socketid{}}} ->
	    %% keep looking, setting SomeOutbound to 'true'
	    outbound_get_best_local2(LocalNode, T, true);
	false ->
	    %% keep looking
	    outbound_get_best_local2(LocalNode, T, SomeOutbound)
    end;
outbound_get_best_local2(_LocalNode, [], _SomeOutbound = true) ->
    nomatch;
outbound_get_best_local2(_LocalNode, [], _SomeOutbound = false) ->
    none.

route_request_host_is_this_proxy(Request) when is_record(Request, request) ->
    %% This function is obsolete now that we use RFC3327 Path instead of the contact-in-URI encoding
    %% when routing requests to outgoingproxys
    URI = Request#request.uri,
    case url_param:find(URI#sipurl.param_pairs, "addr") of
	[Addr] ->
	    ParsedAddr = sipurl:parse(Addr),
	    case siplocation:get_user_with_contact(ParsedAddr) of
		none ->
		    logger:log(normal, "outgoingproxy: Decoded real destination ~p which "
			       "does not appear to belong to any of our users, POSSIBLE RELAY ATTEMPT",
			       [Addr]),
		    %% XXX proxy should be changed to relay when we have verified that this does
		    %% not break anything
		    {proxy, ParsedAddr};
		SipUser ->
		    logger:log(normal, "outgoingproxy: Decoded real destination ~p (user ~p)",
			       [Addr, SipUser]),
		    {proxy, sipurl:parse(Addr)}
	    end;
	[] ->
	    me
    end.

%%--------------------------------------------------------------------
%% Function: request_to_me(THandler, Request, LogTag)
%%           THandler = term(), server transaction handle
%%           Request  = request record()
%%           LogTag   = string()
%% Descrip.: Request is meant for this proxy, if it is OPTIONS we
%%           respond 200 Ok, otherwise we respond 481 Call/
%%           transaction does not exist.
%% Returns : Does not matter.
%%--------------------------------------------------------------------
request_to_me(THandler, Request, LogTag) when is_record(Request, request), Request#request.method == "OPTIONS" ->
    logger:log(normal, "~s: incomingproxy: OPTIONS to me -> 200 OK", [LogTag]),
    %% XXX The OPTIONS response SHOULD include Accept, Accept-Encoding, Accept-Language, and
    %% Supported headers. RFC 3261 section 11.
    transactionlayer:send_response_handler(THandler, 200, "OK");

request_to_me(THandler, Request, LogTag) when is_record(Request, request) ->
    logger:log(normal, "~s: incomingproxy: non-OPTIONS request to me -> 481 Call/Transaction Does Not Exist",
	       [LogTag]),
    transactionlayer:send_response_handler(THandler, 481, "Call/Transaction Does Not Exist").

%%--------------------------------------------------------------------
%% Function: proxy_request(THandler, Request, Dst)
%%           THandler = term(), server transaction handle
%%           Request  = request record()
%%           Dst      = list() of sipdst record() | sipurl record() |
%%                      route
%% Descrip.: Proxy a request somewhere without authentication.
%% Returns : Does not matter
%%--------------------------------------------------------------------
proxy_request(THandler, Request, Dst) when is_record(Request, request), is_list(Dst) orelse
					       is_record(Dst, sipurl) orelse Dst == route ->
    sippipe:start(THandler, none, Request, Dst, ?SIPPIPE_TIMEOUT).

%%--------------------------------------------------------------------
%% Function: relay_request(Request, Dst, YxaCtx)
%%           Request  = request record()
%%           Dst      = sipdst record() | sipurl record() | route
%%           YxaCtx   = yxa_ctx record()
%% Descrip.: Relay request to remote host. If there is not valid
%%           credentials present in the request, challenge user
%%           unless local policy says not to. Never challenge
%%           CANCEL or BYE since they can't be resubmitted and
%%           therefor cannot be challenged.
%% Returns : Does not matter
%%--------------------------------------------------------------------

%%
%% CANCEL or BYE
%%
relay_request( #request{method = Method} = Request, Dst, YxaCtx) when Method == "CANCEL"; Method == "BYE" ->
    #yxa_ctx{thandler   = THandler,
	     app_logtag = LogTag
	    } = YxaCtx,
    logger:log(normal, "~s: outgoingproxy: Relay ~s ~s (unauthenticated)",
	       [LogTag, Request#request.method, sipurl:print(Request#request.uri)]),
    sippipe:start(THandler, none, Request, Dst, ?SIPPIPE_TIMEOUT);

%%
%% Anything but CANCEL or BYE
%%
relay_request(Request, Dst, YxaCtx) when is_record(Request, request) ->
    #yxa_ctx{thandler   = THandler,
	     origin     = Origin,
	     app_logtag = LogTag
	    } = YxaCtx,
    {Method, Header} = {Request#request.method, Request#request.header},
    case sipauth:get_user_verified_proxy(Header, Method) of
	{authenticated, User} ->
	    logger:log(debug, "Relay: User ~p is authenticated", [User]),
	    logger:log(normal, "~s: outgoingproxy: Relay ~s (authenticated)", [LogTag, relay_dst2str(Dst)]),
	    sippipe:start(THandler, none, Request, Dst, ?SIPPIPE_TIMEOUT);
	{stale, User} ->
	    case local:outgoingproxy_challenge_before_relay(Origin, Request, Dst) of
		false ->
		    logger:log(debug, "Relay: STALE authentication (user ~p), but local policy says we "
			       "should not challenge", [User]),
		    sippipe:start(THandler, none, Request, Dst, ?SIPPIPE_TIMEOUT);
		true ->
		    logger:log(debug, "Relay: STALE authentication, sending challenge"),
		    logger:log(normal, "~s: outgoingproxy: Relay ~s -> STALE authentication (user ~p) ->"
			       " 407 Proxy Authentication Required",
			       [LogTag, relay_dst2str(Dst), User]),
		    transactionlayer:send_challenge(THandler, proxy, true, none)
	    end;
	false ->
            case local:outgoingproxy_challenge_before_relay(Origin, Request, Dst) of
                false ->
                    logger:log(debug, "Relay: Failed authentication, but local policy says we should not challenge"),
                    sippipe:start(THandler, none, Request, Dst, ?SIPPIPE_TIMEOUT);
                true ->
		    logger:log(debug, "Relay: Failed authentication, sending challenge"),
		    logger:log(normal, "~s: outgoingproxy: Relay ~s -> 407 Proxy Authorization Required",
			       [LogTag, relay_dst2str(Dst)]),
		    transactionlayer:send_challenge(THandler, proxy, false, none)
	    end
    end.

relay_dst2str(URI) when is_record(URI, sipurl) ->
    sipurl:print(URI);
relay_dst2str(route) ->
    "according to Route header";
relay_dst2str(_) ->
    "unknown dst".
