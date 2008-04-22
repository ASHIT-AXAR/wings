%%
%%  wpc_circularise.erl --
%%
%%    Plugin to flatten, equalise, and inflate an edge loop to its minimum or
%%    user specified diameter.
%%
%%  Copyright (c) 2008 Richard Jones.
%%
%%  See the file "license.terms" for information on usage and redistribution
%%  of this file, and for a DISCLAIMER OF ALL WARRANTIES.
%%

-module(wpc_circularise).
-export([init/0,menu/2,command/2]).
-include("wings.hrl").

init() ->
    true.

%%%% Menu
menu({edge},Menu) ->
    lists:reverse(parse(Menu, [], false));
menu(_,Menu) ->
    Menu.

parse([], NewMenu, true) ->
    NewMenu;
parse([], NewMenu, false) ->
    [circularise(), separator|NewMenu];
parse([A = {_,loop_cut,_}|Rest], NewMenu, false) ->
    parse(Rest, [A,circularise()|NewMenu], true);
parse([Elem|Rest], NewMenu, Found) ->
    parse(Rest, [Elem|NewMenu], Found).

circularise() ->
    {?__(1,"Circularise"),circularise_options(),
      {?__(2,"Flatten, equalise, and inflate selected edge loop making it circular"),[],
       ?__(3,"Pick Center, Plane, and Vertex or Edge marking Stable Ray from center")},[]}.

circularise_options() ->
    fun
      (1,_Ns) -> {edge,circularise};
      (3,_Ns) -> {edge,{circularise,{'ASK',[center,plane]}}};
      (_,_) -> ignore
    end.

%%%% Commands
command({edge,circularise},St) ->
    circle_setup(St);
command({edge,{circularise,{'ASK',Ask}}},#st{shapes=Shs,sel=[{Id,Sel}]}=St) ->
    We = gb_trees:get(Id,Shs),
    Edges = gb_sets:to_list(Sel),
      case wings_edge_loop:edge_loop_vertices(Edges, We) of
        [Vs] ->
            wings:ask(selection_ask(Ask), St, fun({Center,Plane},St0) ->
            second_ask(Center,Plane,Edges,Vs,We,St0)
            end);
        _ -> sel_error()
      end;
command({edge,{circularise,{'ASK',_Ask}}},_St) ->
    sel_error();
command({_,{circularise,_}},St) ->
    command({edge,{circularise,{'ASK',[center,plane]}}},St);
command(_,_) -> next.


%%%% Asks
selection_ask(Asks) ->
    Ask = selection_ask(Asks,[]),
    {Ask,[],[],[vertex, edge, face]}.
selection_ask([],Ask) -> lists:reverse(Ask);

selection_ask([center|Rest],Ask) ->
    Desc = ?__(1,"Pick Center"),
    selection_ask(Rest,[{point,Desc}|Ask]);

selection_ask([plane|Rest],Ask) ->
    Desc = ?__(2,"Pick Plane"),
    selection_ask(Rest,[{axis,Desc}|Ask]).

second_ask(Center,Plane,Edges,Vs,We,St) ->
    wings:ask(secondary_sel_ask(Edges,Vs), St, fun(RayPos,St0) ->
    circle_pick_all_setup(Vs,RayPos,Center,Plane,We,St0)
    end).

secondary_sel_ask(Edges,Vs) ->
    Desc = ?__(1,"Select a single vertex or edge from the original edge loop designating a stable ray from the center point"),
    Data = fun
             (check, #st{selmode=vertex}=St) ->
               check_selection(St,Vs);
             (check, #st{selmode=edge}=St) ->
               check_selection(St,Edges);
             (exit, {_,_,#st{shapes=Shs,selmode=vertex,sel=[{Id,Sel}]}=St}) ->
               case check_selection(St,Vs) of
                 {_,[]} ->
                   We = gb_trees:get(Id, Shs),
                   {_,{RayVs,_,_}} = Sel,
                   RayPos = wings_vertex:pos(RayVs, We),
                   {[],[RayPos]};
                 {_,_} -> error
                end;
             (exit, {_,_,#st{shapes=Shs,selmode=edge,sel=[{Id,Sel}]}=St}) ->
               case check_selection(St,Edges) of
                 {_,[]} ->
                   We = gb_trees:get(Id, Shs),
                   {_,{RayEdge,_,_}} = Sel,
                   #edge{vs=V0s,ve=V0e} = gb_trees:get(RayEdge, We#we.es),
                   VPos1 = wings_vertex:pos(V0s, We),
                   VPos2 = wings_vertex:pos(V0e, We),
                   RayPos = e3d_vec:average(VPos1, VPos2),
                   {[],[RayPos]};
                 {_,_} -> error
               end;
             (exit,_) -> error
           end,
    {[{Data,Desc}],[],[],[vertex,edge]}.

check_selection(#st{sel=[]},_Vs) ->
    {none,?__(1,"Nothing selected")};
check_selection(#st{selmode=vertex,sel=[{_Id,{1,{Vert,_,_}}}]}, Vs) ->
    case lists:member(Vert,Vs) of
      true -> {none,[]};
      false -> {none,?__(2,"Vertex must be from the original edge loop")}
    end;
check_selection(#st{selmode=edge, sel=[{_Id,{1,{Edge,_,_}}}]}, Edges) ->
    case lists:member(Edge,Edges) of
      true -> {none,[]};
      false -> {none,?__(3,"Edge must be from the original edge loop")}
    end;
check_selection(_, _) ->
    {none,?__(4,"Only a single vertex or edge may be selected")}.

%%%% Setup RMB
circle_pick_all_setup(Vs,RayPos,Center,Axis0,#we{vp=Vtab,id=Id}=We,St) ->
    Axis = e3d_vec:norm(Axis0),
    Deg = (360.0/length(Vs)),
    {Pos,Num} = get_radius_rmb(Vs,RayPos,Center,Axis,Vtab,{0.0,0.0,0.0},lastpos,firstpos,0.0,0.0),
    VertDegList = degrees_from_static_ray(Vs,Deg,Num,1,[]),
    Ray = e3d_vec:norm(e3d_vec:sub(Pos,Center)),
    VsPos = wings_util:add_vpos(Vs,We),
    Data = {Center,Ray,Axis,Pos,VertDegList},
    Tvs = [{Id,{Vs,make_circular_fun(Data,VsPos)}}],
    Flags = [{mode,{mode(),{none,none,normal}}}],
    wings_drag:setup(Tvs,[percent|[falloff]],Flags,St).

%%%% Setup LMB
circle_setup(St) ->
    Tvs = wings_sel:fold(fun(Edges,We,Acc) ->
      Groups = wings_edge_loop:edge_loop_vertices(Edges, We),
      case Groups =/= none of
        true ->
          TotalVs = length(wings_edge:to_vertices(Edges,We)),
          SumCheck = [length(SubGroup) || SubGroup <- Groups],
          Sum = lists:sum(SumCheck),
          case TotalVs == Sum of
            true -> circle_setup_1(Groups,We,Acc);
            false -> sel_error_1()
          end;
        false ->
          sel_error_2()
      end
    end,[],St),
    Flags = [{mode,{mode(),{none,none,none}}}],
    wings_drag:setup(Tvs,[percent|[falloff]],Flags,St).

circle_setup_1([],_,Acc) ->
    Acc;
circle_setup_1([Vs|Groups],#we{vp=Vtab,id=Id}=We,Acc) ->
    Center = wings_vertex:center(Vs,We),
    Total = length(Vs),
    Deg = 360.0/Total,
    Axis = e3d_vec:norm(wings_face:face_normal_ccw(Vs, Vtab)),
    {MinRadius,Pos,Index} = get_radius(Vs, Center, Axis, Vtab, 0.0, minradius, lastpos, firstpos, 0.0, index),
    VertDegList = degrees_from_static_ray(Vs,Deg,Index,1.0,[]),
    Ray = e3d_vec:norm(e3d_vec:sub(Pos,Center)),
    MinRadiusPos = e3d_vec:add(Center,e3d_vec:mul(Ray,MinRadius)),
    VsPos = wings_util:add_vpos(Vs,We),
    Data = {Center,Ray,Axis,MinRadiusPos,VertDegList},
    circle_setup_1(Groups,We,[{Id,{Vs,make_circular_fun(Data,VsPos)}}|Acc]).

%%%% Return the Index and position of the Point chosen to represent the stable
%%%% ray from the chosen Center point on the chosen Plane.
get_radius_rmb([], RayPos, Center, Plane, _, Pos,LastPos,FirstPos,AtIndex,Index) ->
    HalfPos = e3d_vec:average(LastPos,FirstPos),
    case HalfPos == RayPos of
      true ->
        PosOnPlane = intersect_vec_plane(HalfPos,Center,Plane),
        {PosOnPlane,AtIndex+0.5};
      false ->
        {Pos,Index}
    end;

get_radius_rmb([Vert|Vs], RayPos, Center, Plane, Vtab, Pos0, lastpos, firstpos, 0.0, Index) ->
    Pos = gb_trees:get(Vert,Vtab),
    case Pos == RayPos of
      true  ->
        PosOnPlane = intersect_vec_plane(Pos,Center,Plane),
        get_radius_rmb(Vs, RayPos, Center, Plane, Vtab, PosOnPlane, Pos, Pos, 1.0, 1.0);
      false ->
        get_radius_rmb(Vs, RayPos, Center, Plane, Vtab, Pos0, Pos, Pos, 1.0, Index)
    end;

get_radius_rmb([Vert|Vs], RayPos, Center, Plane, Vtab, Pos0, LastPos, FirstPos, AtIndex, Index) ->
    Pos = gb_trees:get(Vert,Vtab),
    case Pos == RayPos of
      true  ->
        PosOnPlane = intersect_vec_plane(Pos,Center,Plane),
        get_radius_rmb(Vs, RayPos, Center, Plane, Vtab, PosOnPlane, Pos, FirstPos, AtIndex+1.0, AtIndex+1.0);
      false ->
        HalfPos = e3d_vec:average(Pos,LastPos),
        case HalfPos == RayPos of
          true ->
            PosOnPlane = intersect_vec_plane(HalfPos,Center,Plane),
            get_radius_rmb(Vs, RayPos, Center, Plane, Vtab, PosOnPlane, Pos, FirstPos, AtIndex+1.0, AtIndex+0.5);
        false ->
            get_radius_rmb(Vs, RayPos, Center, Plane, Vtab, Pos0, Pos, FirstPos, AtIndex+1.0, Index)
      end
    end.

%%%% Return the Index and Postion of the Vertex or midpoint between adjacent
%%%% vertices closeest to the Center. Distance calculation is made after the
%%%% point in question is flattened to the relevant Plane.
get_radius([],Center,_,_,MinDist,Pos,LastPos,FirstPos,AtIndex,Index) ->
    HalfPos = e3d_vec:average(LastPos,FirstPos),
    DistHalf = abs(e3d_vec:dist(HalfPos,Center)),
    case DistHalf < MinDist of
      true -> {DistHalf, HalfPos, AtIndex+0.5};
      false -> {MinDist, Pos, Index}
    end;

get_radius([Vert|Vs], Center, Plane, Vtab, 0.0, _Pos, _LastPos, _FirstPos, AtIndex, _Index) ->
    Pos = gb_trees:get(Vert,Vtab),
    PosOnPlane = intersect_vec_plane(Pos,Center,Plane),
    Dist = abs(e3d_vec:dist(PosOnPlane,Center)),
    get_radius(Vs, Center, Plane, Vtab, Dist, PosOnPlane, Pos, Pos, AtIndex+1.0, AtIndex+1.0);

get_radius([Vert|Vs], Center, Plane, Vtab, MinDist, Pos0, LastPos, FirstPos, AtIndex, Index) ->
    Pos = gb_trees:get(Vert,Vtab),
    PosOnPlane = intersect_vec_plane(Pos,Center,Plane),
    HalfPos = e3d_vec:average(PosOnPlane,LastPos),
    DistFull = abs(e3d_vec:dist(PosOnPlane,Center)),
    DistHalf = abs(e3d_vec:dist(HalfPos,Center)),
    case DistFull < DistHalf of
      true ->
        case ((DistFull < MinDist) andalso (DistFull > 0.0)) of
          true  -> get_radius(Vs, Center, Plane, Vtab, DistFull, PosOnPlane, PosOnPlane, FirstPos, AtIndex+1.0, AtIndex+1.0);
          false -> get_radius(Vs, Center, Plane, Vtab, MinDist, Pos0, PosOnPlane, FirstPos, AtIndex+1.0, Index)
        end;
      false ->
        case ((DistHalf < MinDist) andalso (DistHalf > 0.0)) of
          true  -> get_radius(Vs, Center, Plane, Vtab, DistHalf, HalfPos, PosOnPlane, FirstPos, AtIndex+1.0, AtIndex+0.5);
          false -> get_radius(Vs, Center, Plane, Vtab, MinDist, Pos0, PosOnPlane, FirstPos, AtIndex+1.0, Index)
        end
    end.

%%%% Return a tuple list [{Vert, Degrees}] of all the vertices
%%%% in the edge loop in ccw order and the number of degrees it
%%%% will be rotated around the center point from the stable ray.
degrees_from_static_ray([],_,_,_,DegList) ->
    DegList;
degrees_from_static_ray([Vert|Vs],Deg,Num,At,DegList) ->
    Degrees = Deg * (At-Num),
    degrees_from_static_ray(Vs, Deg, Num, At+1.0, [{Vert, Degrees}|DegList]).

%%%% Modes
mode() ->
    fun
      (help, State) -> mode_help(State);
      ({key,$1},{none,none,normal}) -> {none,none,reverse};
      ({key,$1},{none,none,reverse}) -> {none,none,normal};
      (_,_) -> none
    end.

mode_help(State) ->
    [?__(1,"[+] or [-] Adjust Diameter"),
     mode_help_1(State)].
mode_help_1({none,none,normal}) ->
    ?__(1,"  [1] Reverse Plane Normal");
mode_help_1({none,none,reverse}) ->
    ?__(2,"  [1] Original Plane Normal");
mode_help_1({none,none,none}) ->
    [].

%%%% Mode, Diameter, and Percentage changes
make_circular_fun(Data,VsPos) ->
    fun
      (new_falloff,Diameter) ->
          {Center,Ray,Axis,_Pos,VertDegList} = Data,
          NewPos = e3d_vec:add(Center,e3d_vec:mul(Ray,Diameter/2.0)),
          make_circular_fun({Center,Ray,Axis,NewPos,VertDegList},VsPos);
      (new_mode_data,{_N,_}) ->
          {Center,Ray,Axis0,Pos,VertDegList} = Data,
          Axis = e3d_vec:neg(Axis0),
          make_circular_fun({Center,Ray,Axis,Pos,VertDegList},VsPos);
      ([Dist|_], A) ->
          {Center,_Ray,Axis,Pos,VertDegList} = Data,
          make_circular_2(Center,Axis,Pos,VertDegList,VsPos,Dist,A)
    end.

%%%% Find the number of Degrees the Vertex is to be rotated in the VertDegList
make_circular_2(Center,Axis,Pos,VertDegList,VsPos,Dist,A) ->
    lists:foldl(fun({Vertex,Vpos}, VsAcc) ->
      {_,{_,Degrees}} = lists:keysearch(Vertex, 1, VertDegList),
      [{Vertex,make_circular(Center,Axis,Pos,Degrees,Vpos,Dist)}|VsAcc]
    end, A, VsPos).

%%%% Main Function. Calculate the final position of each vertex (NewPos).
%%%% Measure the distance between NewPos and the Center (Factor). Move the
%%%% vertex towards the NewPos by a distance of the drag Dist * Factor.
make_circular(_Center,_Axis,_Pos,_Deg,Vpos,0.0) ->
    Vpos;

make_circular(Center,Axis,Pos,Deg,Vpos,Dist) ->
    NewPos = rotate(Pos,Axis,Center,Deg),
    Norm = e3d_vec:norm(e3d_vec:sub(NewPos,Vpos)),
    Factor = abs(e3d_vec:dist(NewPos,Vpos)),
    e3d_vec:add(Vpos, e3d_vec:mul(Norm, Dist * Factor)).

rotate(Vpos,Axis,{Cx,Cy,Cz},Angle) ->
    A0 = e3d_mat:translate(Cx,Cy,Cz),
    A1 = e3d_mat:mul(A0, e3d_mat:rotate(Angle, Axis)),
    A2 = e3d_mat:mul(A1, e3d_mat:translate(-Cx,-Cy,-Cz)),
    e3d_mat:mul_point(A2,Vpos).

%%%% Helper Functions
intersect_vec_plane(PosA,PosB,_) when PosA == PosB ->
    PosA;
intersect_vec_plane(PosA,PosB,PlaneNorm) ->
    %% Return point where Vector through PosA intersects with plane at PosB
    DotProduct = e3d_vec:dot(PlaneNorm,PlaneNorm),
    case DotProduct of
      0.0 ->
        PosA;
      _ ->
        Intersection = e3d_vec:dot(e3d_vec:sub(PosB,PosA),PlaneNorm)/DotProduct,
        e3d_vec:add(PosA, e3d_vec:mul(PlaneNorm, Intersection))
    end.

%%%% Selection error
sel_error() ->
    wings_u:error(?__(1,"Selection must form a single closed edge loop")).
sel_error_1() ->
    wings_u:error(?__(1,"Selected edge loops may not share vertices")).
sel_error_2() ->
    wings_u:error(?__(1,"Selection must consist of closed edge loops")).