%%
%%  wings_draw_util.erl --
%%
%%     Utilities for drawing objects.
%%
%%  Copyright (c) 2001-2008 Bjorn Gustavsson
%%
%%  See the file "license.terms" for information on usage and redistribution
%%  of this file, and for a DISCLAIMER OF ALL WARRANTIES.
%%
%%     $Id$
%%

-module(wings_draw_util).
-export([init/0,prepare/3,
	 unlit_face_bin/3,unlit_face_bin/4,
	 force_flat_color/2,force_flat_color/3,good_triangulation/5]).

-define(NEED_OPENGL, 1).
-include("wings.hrl").

init() ->
    P= <<16#DD,16#DD,16#DD,16#DD,16#77,16#77,16#77,16#77,
	 16#DD,16#DD,16#DD,16#DD,16#77,16#77,16#77,16#77,
	 16#DD,16#DD,16#DD,16#DD,16#77,16#77,16#77,16#77,
	 16#DD,16#DD,16#DD,16#DD,16#77,16#77,16#77,16#77,
	 16#DD,16#DD,16#DD,16#DD,16#77,16#77,16#77,16#77,
	 16#DD,16#DD,16#DD,16#DD,16#77,16#77,16#77,16#77,
	 16#DD,16#DD,16#DD,16#DD,16#77,16#77,16#77,16#77,
	 16#DD,16#DD,16#DD,16#DD,16#77,16#77,16#77,16#77,
	 16#DD,16#DD,16#DD,16#DD,16#77,16#77,16#77,16#77,
	 16#DD,16#DD,16#DD,16#DD,16#77,16#77,16#77,16#77,
	 16#DD,16#DD,16#DD,16#DD,16#77,16#77,16#77,16#77,
	 16#DD,16#DD,16#DD,16#DD,16#77,16#77,16#77,16#77,
	 16#DD,16#DD,16#DD,16#DD,16#77,16#77,16#77,16#77,
	 16#DD,16#DD,16#DD,16#DD,16#77,16#77,16#77,16#77,
	 16#DD,16#DD,16#DD,16#DD,16#77,16#77,16#77,16#77,
	 16#DD,16#DD,16#DD,16#DD,16#77,16#77,16#77,16#77>>,
    gl:polygonStipple(P).

%%%
%%% Set material and draw faces.
%%%

prepare(Ftab, #dlo{src_we=We}, St) ->
    prepare(Ftab, We, St);
prepare(Ftab0, We, St) ->
    Ftab = wings_we:visible(Ftab0, We),
    prepare_1(Ftab, We, St).

prepare_1(Ftab, #we{mode=vertex}=We, St) ->
    case {wings_pref:get_value(show_colors),Ftab} of
	{false,[{_,Edge}|_]} when is_integer(Edge) ->
	    Fs0 = sofs:from_external(Ftab, [{face,edge}]),
	    Fs1 = sofs:domain(Fs0),
	    Fs = sofs:to_external(Fs1),
	    {color,{[{wings_color:white(),Fs}],[]},St};
	{false,_} ->
	    {color,{[{wings_color:white(),Ftab}],[]},St};
	{true,_} ->
	    {color,vtx_color_split(Ftab, We),St}
    end;
prepare_1(Ftab, #we{mode=material}=We, St) ->
    {material,prepare_mat(Ftab, We),St}.

prepare_mat(Ftab, We) ->
    case wings_pref:get_value(show_materials) of
	false -> [{default,Ftab}];
	true -> wings_facemat:mat_faces(Ftab, We)
    end.

vtx_color_split([{_,Edge}|_]=Ftab0, We) when is_integer(Edge) ->
    vtx_color_split_1(Ftab0, We, [], []);
vtx_color_split(Ftab, _) ->
    vtx_smooth_color_split(Ftab).

vtx_color_split_1([{Face,Edge}|Fs], We, SameAcc, DiffAcc) ->
    Cols = wings_face:vertex_info(Face, Edge, We),
    case vtx_color_split_2(Cols) of
	different -> vtx_color_split_1(Fs, We, SameAcc, [[Face|Cols]|DiffAcc]);
	Col -> vtx_color_split_1(Fs, We, [{Col,Face}|SameAcc], DiffAcc)
    end;
vtx_color_split_1([], _, SameAcc, DiffAcc) ->
    {wings_util:rel2fam(SameAcc),DiffAcc}.

vtx_color_split_2(Cols0) ->
    case no_colors(Cols0) of
	true ->
	    wings_color:white();
	false ->
	    case Cols0 of
		[C,C|Cols] -> vtx_color_split_3(Cols, C);
		_ -> different
	    end
    end.

vtx_color_split_3([C|Cols], C) -> vtx_color_split_3(Cols, C);
vtx_color_split_3([_|_], _) -> different;
vtx_color_split_3([], C) -> C.

no_colors([{_,_,_}|_]) -> false;
no_colors([_|Cols]) -> no_colors(Cols);
no_colors([]) -> true.

vtx_smooth_color_split(Ftab) ->
    vtx_smooth_color_split_1(Ftab, [], []).

vtx_smooth_color_split_1([{_,Vs}=Face|Fs], SameAcc, DiffAcc) ->
    case vtx_smooth_face_color(Vs) of
	different ->
	    vtx_smooth_color_split_1(Fs, SameAcc, [Face|DiffAcc]);
	Col ->
	    vtx_smooth_color_split_1(Fs, [{Col,Face}|SameAcc], DiffAcc)
    end;
vtx_smooth_color_split_1([], SameAcc, DiffAcc) ->
    {wings_util:rel2fam(SameAcc),DiffAcc}.

vtx_smooth_face_color(Vs) ->
    case smooth_no_colors(Vs) of
	true ->
	    wings_color:white();
	false ->
	    case Vs of
		[[Col|_],[Col|_]|T] ->
		    vtx_smooth_face_color_1(T, Col);
		_ ->
		    different
	    end
    end.

vtx_smooth_face_color_1([[Col|_]|T], Col) ->
    vtx_smooth_face_color_1(T, Col);
vtx_smooth_face_color_1([_|_], _) -> different;
vtx_smooth_face_color_1([], Col) -> Col.

smooth_no_colors([[{_,_,_}|_]|_]) -> false;
smooth_no_colors([_|Cols]) -> smooth_no_colors(Cols);
smooth_no_colors([]) -> true.


%% good_triangulation(Normal, PointA, PointB, PointC, PointD) -> true|false
%%  The points PointA through PointD are assumed to be the vertices of
%%  quadrilateral in counterclockwise order, and Normal should be the
%%  averaged normal for the quad.
%%
%%  This function will determine whether a triangulation created by
%%  joining PointA to PointC is a good triangulation (thus creating
%%  the two triangles PointA-PointB-PointC and PointA-PointC-PointD).
%%  This function returns 'true' if none of the two triangles is degenerated
%%  and the diagonal PointA-PointC is inside the original quad (if the
%%  quad is concave, one of the "diagonals" will be inside the quad).
%%
%%  This function returns 'false' if the PointA-PointC triangulation is
%%  bad. Except for pathoglogical quads (e.g. non-planar or warped), the other
%%  triangulation using the PointB-PointD triangulation should be OK.
%%
good_triangulation({Nx,Ny,Nz}, {Ax,Ay,Az}, {Bx,By,Bz}, {Cx,Cy,Cz}, {Dx,Dy,Dz})
  when is_float(Ax), is_float(Ay), is_float(Az) ->
    %% Construct the normals for the two triangles by calculating the
    %% cross product of two edges in the correct order:
    %%
    %%    NormalTri1 = (PointC-PointA) x (PointA-PointB)
    %%    NormalTri2 = (PointD-PointA) x (PointA-PointC)
    %%
    %% The normals should point in about the same direction as the
    %% normal for the quad. We certainly expect the angle between a
    %% triangle normal and the quad normal to be less than 90
    %% degrees. That can be verified by taking the dot product:
    %%
    %%    Dot1 = QuadNormal . NormalTri1
    %%    Dot2 = QuadNormal . NormalTri2
    %%
    %% Both dot products should be greater than zero. A zero dot product either
    %% means that the triangle normal was not defined (a degenerate triangle) or
    %% that the angle is exactly 90 degrees. A negative dot product means that
    %% the angle is greater than 90 degress, which implies that the PointA-PointC
    %% line is outside the quad.
    %%
    CAx = Cx-Ax, CAy = Cy-Ay, CAz = Cz-Az,
    ABx = Ax-Bx, ABy = Ay-By, ABz = Az-Bz,
    DAx = Dx-Ax, DAy = Dy-Ay, DAz = Dz-Az,
    D1 = Nx*(CAy*ABz-CAz*ABy) + Ny*(CAz*ABx-CAx*ABz) + Nz*(CAx*ABy-CAy*ABx),
    D2 = Nx*(DAz*CAy-DAy*CAz) + Ny*(DAx*CAz-DAz*CAx) + Nz*(DAy*CAx-DAx*CAy),
    good_triangulation_1(D1, D2).

good_triangulation_1(D1, D2) when D1 > 0.0, D2 > 0.0 -> true;
good_triangulation_1(_, _) -> false.

%% force_flat_color(OriginalDlist, Color) -> NewDlist.
%%  Wrap a previous display list (that includes gl:color*() calls)
%%  into a new display lists that forces the flat color Color
%%  on all elements.
force_flat_color(Dl, RGB) ->
    force_flat_color(Dl, RGB, fun() -> ok end).

force_flat_color(OriginalDlist, {R,G,B}, DrawExtra) ->
    Dl = gl:genLists(1),
    gl:newList(Dl, ?GL_COMPILE),
    gl:pushAttrib(?GL_CURRENT_BIT bor ?GL_ENABLE_BIT bor
		  ?GL_POLYGON_BIT bor ?GL_LINE_BIT bor
		  ?GL_COLOR_BUFFER_BIT bor
		  ?GL_LIGHTING_BIT),
    DrawExtra(),
    gl:enable(?GL_LIGHTING),
    gl:shadeModel(?GL_FLAT),
    gl:disable(?GL_LIGHT0),
    gl:disable(?GL_LIGHT1),
    gl:disable(?GL_LIGHT2),
    gl:disable(?GL_LIGHT3),
    gl:disable(?GL_LIGHT4),
    gl:disable(?GL_LIGHT5),
    gl:disable(?GL_LIGHT6),
    gl:disable(?GL_LIGHT7),
    gl:lightModelfv(?GL_LIGHT_MODEL_AMBIENT, {0,0,0,0}),
    gl:materialfv(?GL_FRONT_AND_BACK, ?GL_EMISSION, {R,G,B,1}),
    wings_dl:call(OriginalDlist),
    gl:popAttrib(),
    gl:endList(),
    {call,Dl,OriginalDlist}.

%% Draw a face without any lighting.
unlit_face_bin(Face,#dlo{ns=Ns}, Bin) ->
    case gb_trees:get(Face, Ns) of
	[_|VsPos] ->    unlit_plain_face(VsPos, Bin);
	{_,Fs,VsPos} -> unlit_plain_face(Fs, VsPos, Bin)
    end;
unlit_face_bin(Face, #we{fs=Ftab}=We, Bin) ->
    Edge = gb_trees:get(Face, Ftab),
    unlit_face_bin(Face, Edge, We, Bin).

unlit_face_bin(Face, Edge, We, Bin) ->
    Ps = wings_face:vertex_positions(Face, Edge, We),
    case wings_draw:face_ns_data(Ps) of
	[_|VsPos] -> unlit_plain_face(VsPos, Bin);
	{_,Fs,VsPos} -> unlit_plain_face(Fs, VsPos, Bin)
    end.

unlit_plain_face([{X1,Y1,Z1},{X2,Y2,Z2},{X3,Y3,Z3}], Bin) ->
    <<Bin/binary, 
     X1:?F32,Y1:?F32,Z1:?F32,
     X2:?F32,Y2:?F32,Z2:?F32,
     X3:?F32,Y3:?F32,Z3:?F32>>;
unlit_plain_face([{X1,Y1,Z1},{X2,Y2,Z2},{X3,Y3,Z3},{X4,Y4,Z4}], Bin) ->
    <<Bin/binary, 
     X1:?F32,Y1:?F32,Z1:?F32, 
     X2:?F32,Y2:?F32,Z2:?F32,
     X3:?F32,Y3:?F32,Z3:?F32,
     X3:?F32,Y3:?F32,Z3:?F32,
     X4:?F32,Y4:?F32,Z4:?F32,
     X1:?F32,Y1:?F32,Z1:?F32>>. 

unlit_plain_face(Fs, VsPos, Bin) ->
    unlit_plain_face_1(Fs, list_to_tuple(VsPos), Bin).

unlit_plain_face_1([{A,B,C}|Fs], Vtab, Bin0) ->
    {X1,Y1,Z1} = element(A, Vtab), 
    {X2,Y2,Z2} = element(B, Vtab), 
    {X3,Y3,Z3} = element(C, Vtab),
    Bin = <<Bin0/binary, 
	   X1:?F32,Y1:?F32,Z1:?F32,
	   X2:?F32,Y2:?F32,Z2:?F32,
	   X3:?F32,Y3:?F32,Z3:?F32>>,
    unlit_plain_face_1(Fs, Vtab, Bin);
unlit_plain_face_1([], _, Bin) -> Bin.
