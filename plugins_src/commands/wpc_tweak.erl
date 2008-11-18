%%
%%  wpc_tweak.erl --
%%
%%     Tweak mode plugin.
%%
%%  Copyright (c) 2001-2002 Howard Trickey,
%%                2002-2008 Bjorn Gustavsson.
%%
%%  Various changes and improvements by Andrew Shpagin.
%%  Multiple selections and access to regular Wings commands by Richard Jones.
%%
%%  See the file "license.terms" for information on usage and redistribution
%%  of this file, and for a DISCLAIMER OF ALL WARRANTIES.
%%
%%     $Id$
%%

-module(wpc_tweak).

-export([init/0,menu/2,command/2]).

-define(NEED_OPENGL, 1).
-define(NEED_ESDL, 1).
-include_lib("wings.hrl").
-include_lib("e3d.hrl").

-import(lists, [member/2,foldl/3]).

-record(tweak,
    {tmode,					% wait or drag
     magnet=false,				% true/false
     mag_type=dome,				% magnet type: Type
     mag_r=1.0,				% magnet influence radius
     ox,oy,					% original X,Y
     cx,cy,					% current X,Y
     orig_st,				% keeps undo, selection
     st}).					% wings st record (working)

-record(drag,
    {vs,
     pos0,				%Original position.
     pos,				%Current position.
     mag,
     mm					%original|mirror
    }).

-record(mag,
    {orig,				%Orig pos of vertex being moved.
     vs,				%[{V,Pos,Distance,Influence}]
                        %(not changed while dragging)
     vtab=[]		    %[{V,Pos}] (latest)
    }).

init() ->
    wings_pref:set_default(tweak_xyz,[false,false,false]),
    true.

menu({tools}, Menu0) ->
    Menu0 ++ [separator,
          {?__(1,"Tweak"), tweak,
           ?__(4,"Mode for adjusting geometry quickly.") ++ " " ++
           [{bold,?__(3,"Evoking command toggles Tweak mode On/Off.")}]}
         ];
menu(_, Menu) -> Menu.

command({tools,tweak}, St0) ->
    case wpa:pref_get(?MODULE, sel_mode) of
    {_Mode,_Sh0,Mag,MagType} ->
        MagR = 1.0;
    {_Mode,_Sh0,Mag,MagType,MagR} ->
        ok;
    _ ->
        Mag = false,
        MagType = dome,
        MagR = 1.0
    end,
    St = wings_undo:init(St0),
    wings_draw:refresh_dlists(St),
    T = #tweak{magnet=Mag,mag_type=MagType,mag_r=MagR,
           tmode=wait,orig_st=St0,st=St0},
    help(T),
    {seq,push,update_tweak_handler(T)};
command(_, _) -> next.

shift() -> ?KMOD_SHIFT.
ctrl() -> ?KMOD_CTRL.
alt() -> ?KMOD_ALT.
f1() -> ?SDLK_F1.
f2() -> ?SDLK_F2.
f3() -> ?SDLK_F3.

mod_key_combo() ->
    Mod = sdl_keyboard:getModState(),
    Shift = (Mod band shift()) =/= 0,
    Ctrl = (Mod band ctrl()) =/= 0,
    Alt = (Mod band alt()) =/= 0,
    {Shift,Ctrl,Alt}.
fkey_combo() ->
    Keys = sdl_keyboard:getKeyState(),
    F1 = element(f1()+1,Keys) =/= 0,
    F2 = element(f2()+1,Keys) =/= 0,
    F3 = element(f3()+1,Keys) =/= 0,
    [F1,F2,F3].

%% Event handler for tweak mode
update_tweak_handler(#tweak{st=#st{}=St}=T) ->
    wings:mode_restriction(none),
    wings_wm:current_state(St),
    wings_draw:update_sel_dlist(),
    wings_wm:dirty(),
    {replace,fun(Ev) ->
        handle_tweak_event(Ev, T#tweak{orig_st=St,st=St}) end}.

handle_tweak_event(redraw, #tweak{st=St}=T) ->
    help(T),
    redraw(St),
    draw_magnet(T),
    keep;

handle_tweak_event({vec_command,Command,_}, T) when is_function(Command) ->
    %% Use to execute command with vector arguments (see wings_vec.erl).
    case Command() of
      {save_state,St} ->
          handle_tweak_event1({new_state,St}, T);
      #st{}=St ->
          handle_tweak_event1({new_state,St}, T);
      {drag,Drag} ->
%	  io:format("Drag0 ~p\n",[Drag]),
          wings_drag:do_drag(Drag, none);
      keep -> keep;
      {saved,St} ->
          update_tweak_handler(T#tweak{st=St});
      Other ->
          Other
    end;
handle_tweak_event(revert_state, #tweak{orig_st=St0}=T) ->
    St = clear_temp_sel(St0),
    wings_draw:refresh_dlists(St),
    update_tweak_handler(T#tweak{st=St});

handle_tweak_event({note,menu_aborted}, #tweak{orig_st=St0}=T) ->
    St = clear_temp_sel(St0),
    wings_draw:refresh_dlists(St),
    update_tweak_handler(T#tweak{st=St});
handle_tweak_event({drop,Pos,DropData}, #tweak{st=St}) ->
    wings:handle_drop(DropData, Pos, St);
handle_tweak_event(language_changed, _) ->
    This = wings_wm:this(),
    wings_wm:toplevel_title(This, geom_title(This)),
    wings_wm:menubar(This, get(wings_menu_template)),
    keep;
handle_tweak_event(Ev, #tweak{st=St}=T) ->
    case wings_camera:event(Ev, St) of
      next -> handle_tweak_event0(Ev, T);
      Other ->
          Other
     end.

handle_tweak_event0(#keyboard{sym=?SDLK_ESCAPE}, T) ->
    exit_tweak(T);

handle_tweak_event0(#keyboard{unicode=C}=Ev, #tweak{st=#st{sel=Sel0}=St0}=T) ->
    case tweak_hotkey(C, T) of
      none ->
            St = case Sel0 == [] of
              true ->
                fake_selection(St0);
              false ->
                St0
            end,
            case wings_hotkey:event(Ev,St) of
              next ->
                update_tweak_handler(T#tweak{orig_st=St0,st=St0});
              Action ->
                handle_tweak_event1({action,Action},T#tweak{orig_st=St0,st=St})
            end;
      T1 -> update_tweak_handler(T1)
    end;

handle_tweak_event0(#mousemotion{}=Ev, #tweak{tmode=wait,st=St}=T) ->
    case wings_pick:event(Ev, St) of
      next -> handle_tweak_event1(Ev, T);
      Other -> Other
    end;

handle_tweak_event0(Ev, T) ->
    handle_tweak_event1(Ev, T).

handle_tweak_event1(#mousemotion{x=X,y=Y,state=State,mod=Mod},
            #tweak{tmode=drag,cx=CX,cy=CY,ox=OX,oy=OY}=T0)
            when State =/= ?SDL_BUTTON_RMASK ->
    DX = float(X-CX),
    DY = float(Y-CY),
    DxOrg = float(X-OX),
    DyOrg = float(Y-OY),
    FKeys = fkey_combo(),
    TKeys = wings_pref:get_value(tweak_xyz),
    C = tweak_constraints(FKeys,TKeys,[]),

    Mod1 = (Mod band alt()) =/= 0,
    Mod2 = (Mod band shift()) =/= 0,
    Mod3 = (Mod band ctrl()) =/= 0,

    Cam = wings_pref:get_value(camera_mode),

    Mode=if
         Mod1 and Mod3 -> slide;
         Mod1 and Mod2 -> relax;
         Mod2 and Mod3 -> tangent;
         Mod1	       -> normal;
         State == ?SDL_BUTTON_MMASK andalso Cam == maya -> normal;
         C == [true,true,false] -> xymove;
         C == [false,true,true] -> yzmove;
         C == [true,false,true] -> zxmove;
         C == [true,false,false]  -> xmove;
         C == [false,true,false]  -> ymove;
         C == [false,false,true]  -> zmove;
         true			-> screen
     end,
    do_tweak(DX, DY,DxOrg,DyOrg,Mode),
    T = T0#tweak{cx=X,cy=Y},
    update_tweak_handler(T);

handle_tweak_event1(#mousebutton{button=B,x=X,y=Y,state=?SDL_PRESSED},
            #tweak{tmode=wait,st=St0}=T0) when B == 1; B == 2 ->
    ModKeys = mod_key_combo(),
    Cam = wings_pref:get_value(camera_mode),
    case ModKeys of
      {false,true,false} when B == 1 ->
        wings_pick:paint_pick(X, Y, St0);
      {false,false,true} when B == 1 andalso Cam == mb ->
        wings_pick:paint_pick(X, Y, St0);
      {true,false,false} when B == 1  ->
        wings_pick:marquee_pick(X, Y, St0);
      _Other when
        B == 1 andalso Cam =/= mb;
        B == 1 andalso Cam == mb andalso ModKeys == {false,false,false};
        B == 2 andalso Cam == maya andalso ModKeys == {false,false,false};
        B == 2 andalso Cam == mb  andalso ModKeys =/= {false,true,false}
        andalso ModKeys =/= {false,false,false}->
        case wings_pick:do_pick(X, Y, St0) of
          {add,MM,#st{sel=[{_,Sel}]}=St1} ->
            St = case gb_sets:size(Sel) of
              1 -> St1;
              _ -> St0
            end,
            begin_drag(MM, St, T0),
            do_tweak(0.0, 0.0, 0.0, 0.0, screen),
            T = T0#tweak{tmode=drag,ox=X,oy=Y,cx=X,cy=Y},
            update_tweak_handler(T);
          {add,MM,_} ->
            begin_drag(MM, St0, T0),
            do_tweak(0.0, 0.0, 0.0, 0.0, screen),
            T = T0#tweak{tmode=drag,ox=X,oy=Y,cx=X,cy=Y},
            update_tweak_handler(T);
          {delete,MM,_} ->
            begin_drag(MM, St0, T0),
            do_tweak(0.0, 0.0, 0.0, 0.0, screen),
            T = T0#tweak{tmode=drag,ox=X,oy=Y,cx=X,cy=Y},
            update_tweak_handler(T);
          none when B == 1 ->
            wings_pick:marquee_pick(X, Y, St0);
          none when Cam == maya; Cam == mb ->
            update_tweak_handler(T0)
        end;
      _Other ->
        update_tweak_handler(T0)
    end;

handle_tweak_event1(#mousebutton{button=B,state=?SDL_RELEASED},
            #tweak{tmode=drag}=T) when B == 1; B == 2 ->
    case wings_pref:get_value(camera_mode) of
      maya when B == 2 -> end_drag(T);
      mb when B == 2 -> end_drag(T);
      _Cam when B == 1 -> end_drag(T)
    end;

handle_tweak_event1(#mousemotion{state=?SDL_RELEASED},
            #tweak{tmode=drag}=T) ->
    end_drag(T);

%%%% Right Click Menus
handle_tweak_event1(#mousebutton{button=3,state=?SDL_PRESSED,x=X,y=Y}=Ev0,
        #tweak{st=#st{sel=Sel}=St0}=T) ->
    {GlobalX, GlobalY} = wings_wm:local2global(X,Y),
    case wings_pref:get_value(advanced_menus) of
      false ->
          case Sel =:= [] andalso wings_pref:get_value(use_temp_sel) of
              false ->
                  popup_menu(GlobalX, GlobalY, St0);
              true ->
                  case wings_pick:do_pick(X, Y, St0) of
                      {add,_,St1} ->
                           St = set_temp_sel(St0,St1),
                           wings_wm:current_state(St),
                           wings_draw:refresh_dlists(St),
                           handle_tweak_event1(Ev0,T#tweak{orig_st=St0,st=St});
                       _ ->
                           popup_menu(GlobalX, GlobalY, St0)
                  end
          end;
      true -> keep
    end;

handle_tweak_event1(#mousebutton{button=3,state=?SDL_RELEASED,x=X,y=Y}=Ev0,
        #tweak{st=#st{sel=Sel}=St0}=T) ->
    {GlobalX, GlobalY} = wings_wm:local2global(X,Y),
    case wings_pref:get_value(advanced_menus) of
      true ->
          case Sel =:= [] andalso wings_pref:get_value(use_temp_sel) of
              false ->
                  popup_menu(GlobalX, GlobalY, St0);
              true ->
                  case wings_pick:do_pick(X, Y, St0) of
                      {add,_,St1} ->
                           St = set_temp_sel(St0,St1),
                           wings_wm:current_state(St),
                           wings_draw:refresh_dlists(St),
                           handle_tweak_event1(Ev0,T#tweak{orig_st=St0,st=St});
                       _ ->
                           popup_menu(GlobalX, GlobalY, St0)
                  end
          end;
      false -> keep
    end;

handle_tweak_event1(init_opengl, #tweak{st=St}) ->
    wings:init_opengl(St),
    wings_draw:refresh_dlists(St),
    keep;
handle_tweak_event1(quit=Ev, T) ->
    wings_wm:later(Ev),
    exit_tweak(T);

handle_tweak_event1({current_state,St}, T) ->
    update_tweak_handler(T#tweak{st=St});

handle_tweak_event1({new_state,St0}, #tweak{orig_st=#st{selmode=Mode,sh=Sh}=OrigSt}=T) ->
    St2 = clear_temp_sel(St0),
    case St2#st{selmode=Mode,sh=Sh} =:= OrigSt of
      false ->
        St = wings_undo:save(OrigSt,St2),
        wings_draw:refresh_dlists(St),
        St1 = case St of
           #st{saved=false} -> St;
           _Other -> wings_u:caption(St#st{saved=false})
        end,
        update_tweak_handler(T#tweak{st=St1});
      true ->
        St1 = case St2 of
           #st{saved=false} -> St2;
           _Other -> wings_u:caption(St2#st{saved=false})
        end,
        update_tweak_handler(T#tweak{st=St1})
      end;

handle_tweak_event1({action,Action}, #tweak{tmode=wait,orig_st=OrigSt,st=#st{}=St0}=T) ->
    NoTempSel = OrigSt == St0,
    case Action of
    {view,aim} ->
        wings_view:command(aim, St0),
        update_tweak_handler(T#tweak{st=OrigSt});
    {view,highlight_aim} ->
        HL0 = wings_pref:get_value(highlight_aim_at_unselected),
        HL1 = wings_pref:get_value(highlight_aim_at_selected),
        {_,X,Y} = wings_wm:local_mouse_state(),
        {{_,Cmd0},St1} = case wings_pick:do_pick(X, Y, St0) of
              {add,_,St2} when HL0 =:= true ->
                  {{view,highlight_aim},{add,St0,St2}};
              {delete,_,St2} when HL1 =:= true ->
                  {{view,highlight_aim},{delete,St0,St2}};
              _Other ->
                  {{view,aim}, St0}
        end,
        wings_view:command(Cmd0,St1),
        update_tweak_handler(T#tweak{st=OrigSt});
    {view,Cmd} ->
        case wings_view:command(Cmd,St0) of
            keep -> keep;
            #st{}=St ->
                St1 = clear_temp_sel(St),
                refresh_dlists(Cmd, St1),
                update_tweak_handler(T#tweak{st=St1});
            Other ->
            %io:format("Other ~p\n",[Other]),
              Other
        end;
    {edit,undo_toggle} ->
        St = wings_u:caption(wings_undo:undo_toggle(clear_temp_sel(St0))),
        wings_draw:refresh_dlists(St),
        update_tweak_handler(T#tweak{orig_st=St,st=St});
    {edit,undo} ->
        St = wings_u:caption(wings_undo:undo(clear_temp_sel(St0))),
        wings_draw:refresh_dlists(St),
        update_tweak_handler(T#tweak{orig_st=St,st=St});
    {edit,redo} ->
        St = wings_u:caption(wings_undo:redo(clear_temp_sel(St0))),
        wings_draw:refresh_dlists(St),
        update_tweak_handler(T#tweak{orig_st=St,st=St});

    {select,vertex} when NoTempSel == false ->
        St = OrigSt#st{sh=false, selmode=vertex},
        wings_draw:refresh_dlists(St),
        update_tweak_handler(T#tweak{st=St});
    {select,edge} when NoTempSel == false ->
        St = OrigSt#st{sh=false, selmode=edge},
        wings_draw:refresh_dlists(St),
        update_tweak_handler(T#tweak{st=St});
    {select,face} when NoTempSel == false ->
        St = OrigSt#st{sh=false, selmode=face},
        wings_draw:refresh_dlists(St),
        update_tweak_handler(T#tweak{st=St});
    {select,body} when NoTempSel == false ->
        St = OrigSt#st{sh=false, selmode=body},
        wings_draw:refresh_dlists(St),
        update_tweak_handler(T#tweak{st=St});
    {select,{adjacent,vertex}} when NoTempSel == false ->
        St = OrigSt#st{sh=false, selmode=vertex},
        wings_draw:refresh_dlists(St),
        update_tweak_handler(T#tweak{st=St});
    {select,{adjacent,edge}} when NoTempSel == false ->
        St = OrigSt#st{sh=false, selmode=edge},
        wings_draw:refresh_dlists(St),
        update_tweak_handler(T#tweak{st=St});
    {select,{adjacent,face}} when NoTempSel == false ->
        St = OrigSt#st{sh=false, selmode=face},
        wings_draw:refresh_dlists(St),
        update_tweak_handler(T#tweak{st=St});
    {select,{adjacent,body}} when NoTempSel == false ->
        St = OrigSt#st{sh=false, selmode=body},
        wings_draw:refresh_dlists(St),
        update_tweak_handler(T#tweak{st=St});

    {Menu,Cmd} ->
        do_cmd(Menu, Cmd, T);
    _ -> keep
   end;

handle_tweak_event1({action,Action}, #tweak{tmode=drag}=T) ->
    case Action of
      {select, more} -> do_cmd(select, more, T);
      {select, less} -> do_cmd(select, less, T);
      Action -> keep
    end;

handle_tweak_event1(_, T) ->
    update_tweak_handler(T).

popup_menu(X, Y, #st{sel=[]}=St) ->
    wings_shapes:menu(X, Y, St);
popup_menu(X, Y, #st{selmode=Mode}=St) ->
    case wings_light:is_any_light_selected(St) of
    true -> wings_light:menu(X, Y, St);
    false ->
        case Mode of
        vertex -> wings_vertex_cmd:menu(X, Y, St);
        edge -> wings_edge_cmd:menu(X, Y, St);
        face -> wings_face_cmd:menu(X, Y, St);
        body -> wings_body:menu(X, Y, St)
        end
    end.

exit_tweak(#tweak{st=#st{}=St}=T) ->
    remember_mode(T),
    wings_wm:later({new_state,St}),
    wings_wm:later({current_state,St}),
    pop.

remember_mode(#tweak{magnet=Mag,mag_type=MagType,mag_r=MagR,
             st=#st{selmode=Mode,sh=Sh}}) ->
    wpa:pref_set(?MODULE, sel_mode, {Mode,Sh,Mag,MagType,MagR}).

refresh_dlists(wireframe_selected, _) -> ok;
refresh_dlists(shade_selected, _) -> ok;
refresh_dlists(toggle_wireframe, _) -> ok;
refresh_dlists(orthogonal_view, _) -> ok;
refresh_dlists(aim, _) -> ok;
refresh_dlists(frame, _) -> ok;
refresh_dlists(toggle_lights, _) -> ok;
refresh_dlists({along,_}, _) -> ok;
refresh_dlists({toggle_lights,_}, _) -> ok;
refresh_dlists(_, St) -> wings_draw:refresh_dlists(St).

do_cmd(tools, tweak, #tweak{st=St}=T) ->
    exit_tweak(T#tweak{st=clear_temp_sel(St)});

do_cmd(select, less, #tweak{tmode=drag}=T) ->
    update_tweak_handler(magnet_radius(-1,T));

do_cmd(select, more, #tweak{tmode=drag}=T) ->
    update_tweak_handler(magnet_radius(1, T));

do_cmd(Type, Cmd, #tweak{st=#st{}=St0}=T) ->
    St1 = remember_command({Type,Cmd}, St0),
    case wings_plugin:command({Type,Cmd},St1) of
      next -> do_wings_cmd(Type,Cmd,T);
      {save_state,St} ->
          handle_tweak_event1({new_state,St}, T);
      #st{}=St ->
          handle_tweak_event1({new_state,St}, T);
      {drag,Drag} ->
          wings_drag:do_drag(Drag, none);
      keep -> keep;
      Other ->
%	  io:format("Other ~p\n",[Other]),
        Other
    end.

do_wings_cmd(Type,Cmd, #tweak{st=#st{}=St0}=T) ->
    St1 = remember_command({Type,Cmd}, St0),
    Result = cmd_type(Type, Cmd, St1),
    case Result of
      {save_state,St} ->
          handle_tweak_event1({new_state,St}, T);
      #st{}=St ->
          handle_tweak_event1({new_state,St}, T);
      {drag,Drag} ->
          wings_drag:do_drag(Drag, none);
      keep -> keep;
      {saved,St} ->
          update_tweak_handler(T#tweak{st=St});
      {new,St} ->
          handle_tweak_event1({new_state,St}, T);
      quit ->
          exit_tweak(T),
          wings:save_windows(),
          exit(normal);
      Other ->
%	  io:format("Other ~p\n",[Other]),
        Other
    end.

cmd_type(select, Cmd, St) -> wings_sel_cmd:command(Cmd, St#st{temp_sel=none});
cmd_type(Menu, Cmd, St) -> wings:command({Menu, Cmd}, St).

remember_command({C,_}=Cmd, St) when C =:= vertex; C =:= edge;
                     C =:= face; C =:= body ->
    St#st{repeatable=Cmd,ask_args=none,drag_args=none};
remember_command(_Cmd, St) -> St.

redraw(St) ->
    wings:redraw(St),
    keep.

begin_drag(MM, St, T) ->
    wings_draw:refresh_dlists(St),
    wings_dl:map(fun(D, _) ->
             begin_drag_fun(D, MM, St, T)
         end, []).

begin_drag_fun(#dlo{src_sel={body,_},src_we=#we{vp=Vtab}=We}=D, _MM, _St, _T) ->
    Vs = gb_trees:keys(Vtab),
    Center = wings_vertex:center(Vs, We),
    Id = e3d_mat:identity(),
    D#dlo{drag={matrix,Center,Id,e3d_mat:expand(Id)}};

begin_drag_fun(#dlo{src_sel={Mode,Els},src_we=We}=D0, MM, St, T) ->
    Vs0 = sel_to_vs(Mode, gb_sets:to_list(Els), We),
    Center = wings_vertex:center(Vs0, We),
    {Vs,Magnet} = begin_magnet(T, Vs0, Center, We),
    D = wings_draw:split(D0, Vs, St),
    D#dlo{drag=#drag{vs=Vs0,pos0=Center,pos=Center,mag=Magnet,mm=MM}};
begin_drag_fun(D, _, _, _) -> D.

end_drag(#tweak{st=St0}=T) ->
    St = wings_dl:map(fun end_drag/2, St0),
    help(T),
    handle_tweak_event1({new_state,St},T#tweak{tmode=wait}).

end_drag(#dlo{src_we=#we{id=Id},drag=#drag{}}=D0, #st{shapes=Shs0}=St0) ->
    #dlo{src_we=We} = D = wings_draw:join(D0),
    St = case mod_key_combo() of
        {true,true,true} ->
            Shs = gb_trees:update(Id,collapse_short_edges(0.0001,We), Shs0),
            St0#st{shapes=Shs};
        _Otherwise ->
            Shs = gb_trees:update(Id, We, Shs0),
            St0#st{shapes=Shs}
    end,
    {D#dlo{vs=none,sel=none,drag=none},St};
end_drag(#dlo{src_we=#we{id=Id},drag={matrix,_,Matrix,_},
          proxy_data=Pd}, #st{shapes=Shs0}=St0) ->
    We0 = gb_trees:get(Id, Shs0),
    We = wings_we:transform_vs(Matrix, We0),
    Shs = gb_trees:update(Id, We, Shs0),
    St = St0#st{shapes=Shs},
    D = #dlo{src_we=We,proxy_data=Pd},
    {wings_draw:changed_we(D, D),St};
end_drag(D, St) -> {D,St}.

sel_to_vs(Mode, _, We) when ?IS_LIGHT(We) ->
    gb_sets:to_list(wings_sel:get_all_items(Mode, We));
sel_to_vs(vertex, Vs, _) -> Vs;
sel_to_vs(edge, Es, We) -> wings_vertex:from_edges(Es, We);
sel_to_vs(face, [Face], We) -> wings_face:vertices_ccw(Face, We);
sel_to_vs(face, Fs, We) -> wings_face:to_vertices(Fs, We).

do_tweak(DX, DY, DxOrg,DyOrg,Mode) ->
    wings_dl:map(fun
        (#dlo{src_we=We}=D, _) when ?IS_LIGHT(We) ->
             do_tweak(D, DX, DY, DxOrg, DyOrg, screen);
        (D, _) ->
             do_tweak(D, DX, DY, DxOrg, DyOrg, Mode)
         end, []).

%%
%%  Additional functions for lookup around vertex
%%

collect_neib_faces(V,#we{mirror=MirrorFace}=We) ->
    %% The We is not a complete one, but from the display lists. Therefore,
    %% the face table is not complete. In particular, it does not contain
    %% hidden faces (negative face numbers), so we must ignore any negative
    %% face number.
    wings_vertex:fold(fun(_, Face, _, A) when Face =/= MirrorFace,
                          Face >= 0 ->
                  [Face|A];
             (_,_,_,A) ->
                  A
              end, [],V,We).

collect_neib_verts(V,#we{es=Es}=We) ->
    Facelist=collect_neib_faces(V,We),
    foldl(fun(Face,D) ->
          Edges = wings_face:to_edges([Face], We),
          NearVerts=foldl(fun(E,B) ->
                      #edge{vs=Vs,ve=Ve}=gb_trees:get(E,Es),
                      if
                          V==Vs -> [Ve|B];
                          V==Ve -> [Vs|B];
                          true -> B
                      end
                  end,[],Edges),
          NearVerts ++ D
      end, [],Facelist).

check_if_face_contains_vs(Face,We,Vs)->
    Verts=wings_face:to_vertices([Face],We),
    foldl(fun({Vert,_,_,_,_},P)->
          case member(Vert,Verts) of
              true -> P;
              _ -> none
          end
      end,all,Vs).

check_if_Vs_have_V(V,Vs)->
    foldl(fun({VinVs,_,_,_,_},Res)-> if VinVs==V -> true; true->Res end end,false,Vs).

check_if_Vs_have_V12(V1,V2,Vs)->
    case check_if_Vs_have_V(V1,Vs) of
    true -> check_if_Vs_have_V(V2,Vs);
    _ -> false
    end.

get_nverts(Vs)->
    foldl(fun(_,S)->S+1 end,0,Vs).

collect_neib_verts_vs(V,#we{es=Es}=We,Vs) ->
    Facelist0=collect_neib_faces(V,We),
    Facelist=case get_nverts(Vs) of
         2-> foldl(fun(Face,FL)->
                   Res=check_if_face_contains_vs(Face,We,Vs),
                   case	Res of
                       all -> [Face|FL];
                       _ ->FL
                   end
               end,[],Facelist0);
         _->Facelist0
         end,
    foldl(fun(Face,D) ->
          Edges = wings_face:to_edges([Face], We),
          NearVerts=foldl(fun(E,B) ->
                      Edg=gb_trees:get(E,Es),
                      #edge{vs=VS,ve=VE}=Edg,
                      Have= case get_nverts(Vs) of
                            2 -> check_if_Vs_have_V12(VE,VS,Vs);
                            _ ->false
                        end,
                      if
                          Have==true -> B;
                          V==VS -> [VE|B];
                          V==VE -> [VS|B];
                          true -> B
                      end
                  end,[],Edges),
          NearVerts ++ D
      end, [],Facelist).

collect_neib_verts_coor(V,We)->
    VertList=collect_neib_verts(V,We),
    foldl(fun(E,B) -> [wings_vertex:pos(E,We)|B] end,[],VertList).

get_orig_pos(V,We,Vs)->
    Pos=foldl(
      fun({Vert,Coor,_,_,_},P) ->
          if V==Vert -> Coor; true-> P end
      end,none,Vs),
    case Pos of
    none -> wings_vertex:pos(V,We);
    _ -> Pos
    end.

collect_neib_verts_coor_vs(V,We,Vs)->
    VertList=collect_neib_verts_vs(V,We,Vs),
    foldl(fun(E,B) -> [get_orig_pos(E,We,Vs)|B] end,[],VertList).

sub_pos_from_list(List,Pos) ->
    foldl(fun(E,B) -> [e3d_vec:sub(E,Pos)|B] end,[],List).

relax_vec(V, We) ->
    case collect_neib_verts_coor(V, We) of
    [] ->
        %% Because of hidden faces there may be no neighbouring vertices,
        %% so we default to the position of the vertex itself.
        wings_vertex:pos(V, We);
    Cs ->
        e3d_vec:average(Cs)
    end.

slide_one_vec(Vpos, TweakPos, _, PosList) ->
    Dpos=e3d_vec:sub(TweakPos,Vpos),
    {Dp,_}=
    foldl(
      fun(Vec,{VP,W}) ->
          Vn=e3d_vec:norm(Vec),Dotp0=e3d_vec:dot(Vn,Dpos),Len=e3d_vec:len(Vec),
          {Dotp,Sign}=if Dotp0<0 -> {-Dotp0/1.5,-1.0}; true -> {Dotp0,1.0} end,
          Dotp2 = if Dotp>Len ->Len; true -> Dotp end,
          if Dotp>W -> {e3d_vec:mul(Vn,Dotp2*Sign),Dotp}; true -> {VP,W} end
      end,{{0,0,0},0},PosList),
    e3d_vec:add(Vpos,Dp).

slide_vec_w(V, Vpos0, VposS, TweakPosS, We, W,Vs) ->
    Dv=e3d_vec:sub(VposS,Vpos0),
    Vpos=Vpos0,
    TweakPos=e3d_vec:sub(TweakPosS,Dv),
    Cs=sub_pos_from_list(collect_neib_verts_coor_vs(V,We,Vs),Vpos),
    TweakPos2=e3d_vec:add(Vpos,e3d_vec:mul(e3d_vec:sub(TweakPos,Vpos),W)),
    slide_one_vec(Vpos, TweakPos2, We, Cs).

relax_vec(V, #we{}=We,Pos0,Pos,Weight) ->
    Vec=relax_vec(V,We),
    Len=e3d_vec:dist(Pos0,Pos),
    Len1=if Len>1 -> 1.0; true -> Len end,
    D=e3d_vec:sub(Vec,Pos0),
    e3d_vec:add_prod(Pos0,D,Len1*Weight).

relax_vec_fn(V, #we{}=We,Pos0,Weight) ->
    Vec=relax_vec(V,We),
    D=e3d_vec:sub(Vec,Pos0),
    e3d_vec:add_prod(Pos0,D,Weight).

%%
%% scanning over the mesh to collapse short edges
%%

collapse_short_edges(Tolerance, #we{es=Etab,vp=Vtab}=We) ->
    Short = foldl(
          fun({Edge,#edge{vs=Va,ve=Vb}}, A) ->
              case gb_trees:is_defined(Va,Vtab) of
              true->
                  case gb_trees:is_defined(Vb,Vtab) of
                  true->
                      VaPos = wings_vertex:pos(Va, We),
                      VbPos = wings_vertex:pos(Vb, We),
                      case abs(e3d_vec:dist(VaPos, VbPos)) of
                      Dist when Dist < Tolerance -> [Edge|A];
                      _Dist -> A
                      end;
                  false-> A
                  end;
              false -> A
              end
          end, [], gb_trees:to_list(Etab)),
    try wings_collapse:collapse_edges(Short,We)
    catch _:_What->We
    end.

%%
%% end of additional geo-functions block
%%

do_tweak(#dlo{drag={matrix,Pos0,Matrix0,_},src_we=#we{id=Id}}=D0,
     DX,DY,_,_,Mode) ->
    Matrices = wings_u:get_matrices(Id, original),
    {Xs,Ys,Zs} = obj_to_screen(Matrices, Pos0),
    TweakPos = screen_to_obj(Matrices, {Xs+DX,Ys-DY,Zs}),
    {Tx,Ty,Tz} = TweakPos,
    {Px,Py,Pz} = Pos0,
    Pos = case Mode of
        xmove -> {Tx,Py,Pz};
        ymove -> {Px,Ty,Pz};
        zmove -> {Px,Py,Tz};
        xymove -> {Tx,Ty,Pz};
        yzmove -> {Px,Ty,Tz};
        zxmove -> {Tx,Py,Tz};
        _Other -> TweakPos
    end,
    Move = e3d_vec:sub(Pos, Pos0),
    Matrix = e3d_mat:mul(e3d_mat:translate(Move), Matrix0),
    D0#dlo{drag={matrix,Pos,Matrix,e3d_mat:expand(Matrix)}};

do_tweak(#dlo{drag=#drag{vs=Vs,pos=Pos0,pos0=Orig,mag=Mag0,mm=MM}=Drag,
          src_we=#we{id=Id}=We}=D0, DX, DY, DxOrg, DyOrg,Mode) ->
    Matrices = wings_u:get_matrices(Id, MM),
    {Xs,Ys,Zs} = obj_to_screen(Matrices, Pos0),
    TweakPos = screen_to_obj(Matrices, {Xs+DX,Ys-DY,Zs}),
    [V2|_]=Vs,
    {Tx,Ty,Tz} = TweakPos,
    {Px,Py,Pz} = Pos0,
    {Vtab,Mag} =
    case Mode of
        xmove -> Pos = {Tx,Py,Pz},
             magnet_tweak(Mag0, Pos);
        ymove -> Pos = {Px,Ty,Pz},
             magnet_tweak(Mag0, Pos);
        zmove -> Pos = {Px,Py,Tz},
             magnet_tweak(Mag0, Pos);
        xymove -> Pos = {Tx,Ty,Pz},
              magnet_tweak(Mag0, Pos);
        yzmove -> Pos = {Px,Ty,Tz},
              magnet_tweak(Mag0, Pos);
        zxmove -> Pos = {Tx,Py,Tz},
              magnet_tweak(Mag0, Pos);
        relax -> Pos=relax_vec(V2,We,Pos0,TweakPos,1.0),
              Len=(abs(DxOrg)+abs(DyOrg))/200.0,
              Len1=case Len>1 of
                   true -> 1.0;
                   false -> Len
               end,
              magnet_tweak_fn(Mag0, Pos,We,Len1);
        slide -> Pos=TweakPos,
              magnet_tweak_slide_fn(Mag0, We,Orig,TweakPos);
        normal -> Pos=tweak_pos(true,false,Vs, Pos0, TweakPos, D0),
              magnet_tweak(Mag0, Pos);
        tangent -> Pos=tweak_pos(false,true,Vs, Pos0, TweakPos, D0),
              magnet_tweak(Mag0, Pos);
        _ 	-> Pos =  TweakPos,
              magnet_tweak(Mag0, Pos)
    end,
    D = D0#dlo{sel=none,drag=Drag#drag{pos=Pos,mag=Mag}},
    wings_draw:update_dynamic(D, Vtab);
do_tweak(D, _, _, _, _, _) -> D.

obj_to_screen({MVM,PM,VP}, {X,Y,Z}) ->
    glu:project(X, Y, Z, MVM, PM, VP).

screen_to_obj({MVM,PM,VP}, {Xs,Ys,Zs}) ->
    glu:unProject(Xs, Ys, Zs, MVM, PM, VP).

tweak_pos(false, true, _, Pos0, TweakPos, #dlo{src_we=#we{}=We,src_sel={face,Sel0}}) ->
    Faces = gb_sets:to_list(Sel0),
    FaceRegions = wings_sel:strict_face_regions(Faces,We),
    Normals = face_region_normals(FaceRegions,We,[]),
    case Normals of
    [[]] -> TweakPos;
    _Otherwise ->
        N = e3d_vec:average(Normals),
    %% constraining by the plane
    Dot = e3d_vec:dot(N, N),
      if
      Dot == 0.0 -> Pos0;
      true ->
        T = -e3d_vec:dot(N, e3d_vec:sub(TweakPos, Pos0)) / Dot,
        e3d_vec:add_prod(TweakPos, N, T)
      end
    end;

tweak_pos(false, true,Vs, Pos0, TweakPos, D) ->
    Normals = [vertex_normal(V, D) || V <- Vs],
    N = e3d_vec:average(Normals),
    %% constraining by the plane
    Dot = e3d_vec:dot(N, N),
      if
      Dot == 0.0 -> Pos0;
      true ->
        T = -e3d_vec:dot(N, e3d_vec:sub(TweakPos, Pos0)) / Dot,
        e3d_vec:add_prod(TweakPos, N, T)
      end;

%%%% Along Average Normal
tweak_pos(true, false, _, Pos0, TweakPos, #dlo{src_we=#we{}=We,src_sel={face,Sel0}}) ->
    Faces = gb_sets:to_list(Sel0),
    FaceRegions = wings_sel:strict_face_regions(Faces,We),
    Normals = face_region_normals(FaceRegions,We,[]),
    case Normals of
    [[]] -> TweakPos;
    _Otherwise ->
        N = e3d_vec:average(Normals),
        %% Return the point along the normal closest to TweakPos.
        Dot = e3d_vec:dot(N, N),
        if
        Dot == 0.0 -> Pos0;
        true ->
          T = e3d_vec:dot(N, e3d_vec:sub(TweakPos, Pos0)) / Dot,
          e3d_vec:add_prod(Pos0, N, T)
        end
    end;

tweak_pos(true, false, Vs, Pos0, TweakPos, D) ->
    Normals = [vertex_normal(V, D) || V <- Vs],
    N = e3d_vec:average(Normals),
    %% Return the point along the normal closest to TweakPos.
    Dot = e3d_vec:dot(N, N),
      if
      Dot == 0.0 -> Pos0;
      true ->
        T = e3d_vec:dot(N, e3d_vec:sub(TweakPos, Pos0)) / Dot,
        e3d_vec:add_prod(Pos0, N, T)
      end.

%tweak_pos(Pos0, TweakPos, Vector) ->
%    Dot = e3d_vec:dot(Vector,Vector),
%	T = e3d_vec:dot(Vector, e3d_vec:sub(TweakPos, Pos0)) / Dot,
%    e3d_vec:add_prod(Pos0, Vector, T).
%
face_region_normals([Faces|Regions],We,Normals) ->
    Edges = wings_face:outer_edges(Faces, We),
    LoopNorm = loop_norm(Edges, We),
    face_region_normals(Regions,We,[LoopNorm|Normals]);
face_region_normals([],_,Normals) ->
    Normals.

loop_norm([], _) ->
    [];
loop_norm(Edges,We) ->
%%%% Return average normal of multiple loops in a single face region
    Loops = wings_edge_loop:edge_loop_vertices(Edges, We),
    loop_norm_1(Loops, We, []).

loop_norm_1([Vs|Loops], We, Normals) ->
    Norm = wings_face:face_normal_ccw(Vs, We),
    loop_norm_1(Loops, We, [Norm|Normals]);
loop_norm_1([], _, [First|Normals]) ->
    e3d_vec:norm(e3d_vec:average([e3d_vec:neg(First)]++Normals)).

%% vertex_normal(Vertex, DLO) -> UnormalizedNormal
%%  Calculate the vertex normal. Will also work for vertices surrounded
%%  by one or more hidden faces.
vertex_normal(V, D) ->
    OrigWe = wings_draw:original_we(D),
    FaceNs = [face_normal(F, D) || F <- wings_face:from_vs([V], OrigWe)],
    e3d_vec:add(FaceNs).

%% face_normal(Face, DLO) -> Normal
%%  Calculate the face normal. Will also work for faces that
%%  are hidden (including the virtual mirror face).
face_normal(Face, #dlo{src_we=#we{vp=Vtab}}=D) ->
    #we{vp=OrigVtab} = OrigWe = wings_draw:original_we(D),
    Vs = wings_face:vertices_ccw(Face, OrigWe),
    VsPos = [vertex_pos(V, Vtab, OrigVtab) || V <- Vs],
    e3d_vec:normal(VsPos).

vertex_pos(V, Vtab, OrigVtab) ->
    case gb_trees:lookup(V, Vtab) of
    none -> gb_trees:get(V, OrigVtab);
    {value,Pos} -> Pos
    end.

help(#tweak{magnet=false}) ->
    Constraints = [fkey_help(),[{bold,?__(3,"XYZ Constraints")}]++
        ?__(7,"(+[Alt] to Toggle)")],
    Tail = [Constraints,exit_help()],
    All = common_help(Tail),
    Msg = wings_msg:join(All),
    wings_wm:message(Msg, "[1] "++?__(4,"Magnet On"));
help(#tweak{magnet=true,mag_type=Type}) ->
    All = common_help([]),
    Msg = wings_msg:join(All),
    Types = help_1(Type, [{2,dome},{3,straight},{4,spike}]),
    MagMsg = wings_msg:join(["[1] "++?__(5,"Magnet Off"),
                 "[+]/[-] "++?__(6,"Tweak R"),
                 Types]),
    wings_wm:message(Msg, MagMsg).

%% Messages common for magnet and no magnet.
common_help(Tail0) ->
    AltMod = alt(),
    CtrlMod = ctrl(),
    ShiftMod = shift(),
    Cam = wings_pref:get_value(camera_mode),
    Button = case Cam of
        mb -> 2;
        _  -> 1
    end,
    Tail = [slide_help(Button, AltMod, CtrlMod)|Tail0],
    [wings_msg:button_format(?__(2,"Drag")),
     case Cam of
       mb -> wings_msg:mod_format(AltMod,1,?__(6,"Select"));
       _  -> wings_msg:mod_format(CtrlMod,1,?__(6,"Select"))
     end,
     case Cam of
       maya   -> wings_msg:mod_format(0, 2, ?__(3,"Along Normal"));
       _other -> wings_msg:mod_format(AltMod, Button, ?__(3,"Along Normal"))
     end,
     wings_msg:mod_format(CtrlMod bor ShiftMod, Button, ?__(4,"In Tangent Plane")),
     wings_msg:mod_format(AltMod bor ShiftMod, Button, ?__(5,"Relax"))|Tail].

exit_help() ->
    ?__(2,"[Esc]:") ++ " " ++ ?__(1,"Exit").

slide_help(Button, AltMod, CtrlMod) ->
    wings_msg:mod_format(AltMod bor CtrlMod, Button,{bold,?__(1,"Slide")}) ++
    ?__(2,"(+[Shift] to Clean)").

intl_type(dome)     -> ?__(1,"Dome");
intl_type(straight) -> ?__(2,"Straight");
intl_type(spike)    -> ?__(3,"Spike").

help_1(Type, [{Digit,Type}|T]) ->
    wings_msg:join("[" ++ [$0+Digit] ++ "] " ++
           [{bold,intl_type(Type)}],
           help_1(Type, T));
help_1(Type, [{Digit,ThisType}|T]) ->
    wings_msg:join("[" ++ [$0+Digit] ++ "] " ++
           intl_type(ThisType),
           help_1(Type, T));
help_1(_, []) -> [].

fkey_help() ->
    [Fx,Fy,Fz] = wings_pref:get_value(tweak_xyz),
    F1 = case Fx of
        true -> [{bold,"F1"}];
        false -> "F1"
    end,
    F2 = case Fy of
        true -> [{bold,"F2"}];
        false -> "F2"
    end,
    F3 = case Fz of
        true -> [{bold,"F3"}];
        false -> "F3"
    end,
    "["++F1++","++F2++","++F3++"]: ".

fake_selection(St) ->
    wings_dl:fold(fun(#dlo{src_sel=none}, S) ->
              %% No selection, try highlighting.
              fake_sel_1(S);
             (#dlo{src_we=#we{id=Id},src_sel={Mode,Els}}, S) ->
              S#st{selmode=Mode,sel=[{Id,Els}]}
          end, St).

fake_sel_1(St0) ->
    case wings_pref:get_value(use_temp_sel) of
    false -> St0;
    true ->
        {_,X,Y} = wings_wm:local_mouse_state(),
        case wings_pick:do_pick(X, Y, St0) of
        {add,_,St} -> set_temp_sel(St0,St);
        _ -> St0
        end
    end.

set_temp_sel(#st{sh=Sh,selmode=Mode}, St) ->
    St#st{temp_sel={Mode,Sh}}.

clear_temp_sel(#st{temp_sel=none}=St) -> St;
clear_temp_sel(#st{temp_sel={Mode,Sh}}=St) ->
    St#st{temp_sel=none,selmode=Mode,sh=Sh,sel=[]}.

%%%
%%% Magnetic tweak. Standard tweak is a special case of magnetic tweak
%%% (vertices to be moved have the influence set to 1.0).
%%%

tweak_hotkey(C, #tweak{magnet=Mag,mag_type=Type0}=T) ->
    case magnet_hotkey(C) of
    none -> constraint_hotkey();
    toggle when Mag == true ->
        setup_magnet(T#tweak{magnet=false});
    toggle when Mag == false ->
        setup_magnet(T#tweak{magnet=true});
    Type0 -> T;
    Type -> setup_magnet(T#tweak{magnet=true,mag_type=Type})
    end.

constraint_hotkey() ->
%% Alt + F1/2/3 toggles xyx constraints on/off
    Alt = mod_key_combo() == {false,false,true},
    Fkeys = fkey_combo(),
    Constraints = wings_pref:get_value(tweak_xyz),
    case Alt of
      false -> none;
      true when Fkeys =/= [false,false,false] ->
        C = set_constraint_toggles(Fkeys,Constraints,[]),
        wings_pref:set_value(tweak_xyz,C),
        none;
      _other -> none
    end.
set_constraint_toggles([true|Fkeys],[Pref|Constraints],C) ->
    NewC = case Pref of
      true -> false;
      false -> true
    end,
    set_constraint_toggles(Fkeys,Constraints,[NewC|C]);
set_constraint_toggles([false|Fkeys],[Pref|Constraints],C) ->
    set_constraint_toggles(Fkeys,Constraints,[Pref|C]);
set_constraint_toggles([],[],C) ->
    lists:reverse(C).

tweak_constraints([true|Fkeys],[false|Tkeys],Constraints) ->
    tweak_constraints(Fkeys,Tkeys,[true|Constraints]);
tweak_constraints([true|Fkeys],[true|Tkeys],Constraints) ->
    tweak_constraints(Fkeys,Tkeys,[false|Constraints]);
tweak_constraints([_|Fkeys],[Key|Tkeys],Constraints) ->
    tweak_constraints(Fkeys,Tkeys,[Key|Constraints]);
tweak_constraints([],[],Constraints) ->
    lists:reverse(Constraints).

magnet_hotkey($1) -> toggle;
magnet_hotkey($2) -> dome;
magnet_hotkey($3) -> straight;
magnet_hotkey($4) -> spike;
magnet_hotkey(_) -> none.

setup_magnet(#tweak{tmode=drag}=T) ->
    wings_dl:map(fun(D, _) ->
             setup_magnet_fun(D, T)
         end, []),
    do_tweak(0.0, 0.0, 0.0, 0.0,screen),
    wings_wm:dirty(),
    T;
setup_magnet(T) -> T.

setup_magnet_fun(#dlo{drag=#drag{vs=Vs0,pos0=Center}=Drag}=Dl0,
         #tweak{st=St}=T) ->
    We = wings_draw:original_we(Dl0),
    {Vs,Mag} = begin_magnet(T, Vs0, Center, We),
    Dl = wings_draw:split(Dl0, Vs, St),
    Dl#dlo{drag=Drag#drag{mag=Mag}};
setup_magnet_fun(Dl, _) -> Dl.

begin_magnet(#tweak{magnet=false}=T, Vs, Center, We) ->
    Mirror = mirror_info(We),
    Near = near(Center, Vs, [], Mirror, T, We),
    Mag = #mag{orig=Center,vs=Near},
    {[Va || {Va,_,_,_,_} <- Near],Mag};
begin_magnet(#tweak{magnet=true}=T, Vs, Center, #we{vp=Vtab0}=We) ->
    Mirror = mirror_info(We),
    Vtab1 = sofs:from_external(gb_trees:to_list(Vtab0), [{vertex,info}]),
    Vtab2 = sofs:drestriction(Vtab1, sofs:set(Vs, [vertex])),
    Vtab = sofs:to_external(Vtab2),
    Near = near(Center, Vs, Vtab, Mirror, T, We),
    Mag = #mag{orig=Center,vs=Near},
    {[Va || {Va,_,_,_,_} <- Near],Mag}.

near(Center, Vs, MagVs, Mirror, #tweak{mag_r=R,mag_type=Type}, We) ->
    RSqr = R*R,
    M = foldl(fun({V,Pos}, A) ->
              case e3d_vec:dist_sqr(Pos, Center) of
              DSqr when DSqr =< RSqr ->
                  D = math:sqrt(DSqr),
                  Inf = mf(Type, D, R),
                  Matrix = mirror_matrix(V, Mirror),
                  [{V,Pos,Matrix,D,Inf}|A];
              _ -> A
              end;
         (_, A) -> A
          end, [], MagVs),
    foldl(fun(V, A) ->
          Matrix = mirror_matrix(V, Mirror),
          Pos = wpa:vertex_pos(V, We),
          [{V,Pos,Matrix,0.0,1.0}|A]
      end, M, Vs).

mf(dome, D, R) when is_float(R) ->
    math:sin((R-D)/R*math:pi()/2);
mf(straight, D, R) when is_float(R) ->
    (R-D)/R;
mf(spike, D0, R) when is_float(R) ->
    D = (R-D0)/R,
    D*D.

magnet_tweak(#mag{orig=Orig,vs=Vs}=Mag, Pos) ->
    Vec = e3d_vec:sub(Pos, Orig),
    Vtab = foldl(fun({V,P0,Plane,_,1.0}, A) ->
             P1 = e3d_vec:add(P0, Vec),
             P = mirror_constrain(Plane, P1),
             [{V,P}|A];
            ({V,P0,Plane,_,Inf}, A) ->
             P1 = e3d_vec:add_prod(P0, Vec, Inf),
             P = mirror_constrain(Plane, P1),
             [{V,P}|A]
         end, [], Vs),
    {Vtab,Mag#mag{vtab=Vtab}}.

magnet_tweak_fn(#mag{vs=Vs}=Mag, _,We,Weight) ->
    Vtab = foldl(fun({V,P0,Plane,_,1.0}, A) ->
             P1=relax_vec_fn(V,We,P0,Weight),
             P = mirror_constrain(Plane, P1),
             [{V,P}|A];
            ({V,P0,Plane,_,Inf}, A) ->
             P1=relax_vec_fn(V,We,P0,Weight*Inf),
             P = mirror_constrain(Plane, P1),
             [{V,P}|A]
         end, [], Vs),
    {Vtab,Mag#mag{vtab=Vtab}}.

magnet_tweak_slide_fn(#mag{vs=Vs}=Mag, We,Orig,TweakPos) ->
    Vtab = foldl(fun({V,P0,Plane,_,Inf}, A) ->
             P1=slide_vec_w(V,P0,Orig,TweakPos,We,Inf,Vs),
             P = mirror_constrain(Plane, P1),
             [{V,P}|A]
         end, [], Vs),
    {Vtab,Mag#mag{vtab=Vtab}}.

magnet_radius(Sign, #tweak{mag_r=Falloff0,orig_st=St}=T0) ->
    case Falloff0+Sign*?GROUND_GRID_SIZE/10 of
    Falloff when Falloff > 0 ->
        setup_magnet(T0#tweak{mag_r=Falloff,st=St});
    _Falloff -> T0#tweak{st=St}
    end.

get_inv_magnet_value2(MagType,Value,Pos) ->
    Step=0.1,
    V1=mf(MagType,Pos,1.0),
    V2=mf(MagType,Pos+Step,1.0),
    case	Value<V1 andalso Value>=V2 of
    true -> Pos+(V1-Value)/(V1-V2)*Step;
    false -> get_inv_magnet_value2(MagType,Value,Pos+Step)
    end.
get_inv_magnet_value(MagType,Value) ->
    get_inv_magnet_value2(MagType,Value,0.0).

draw_magnet(#tweak{magnet=false}) -> ok;
draw_magnet(#tweak{st=#st{selmode=body}}) -> ok;
draw_magnet(#tweak{mag_r=R,mag_type=Mt}) ->
    gl:pushAttrib(?GL_ALL_ATTRIB_BITS),
    gl:disable(?GL_DEPTH_TEST),
    gl:enable(?GL_BLEND),
    gl:blendFunc(?GL_SRC_ALPHA, ?GL_ONE_MINUS_SRC_ALPHA),
    wings_view:load_matrices(false),
    gl:color4f(0, 0, 1, 0.06),
    R2=[get_inv_magnet_value(Mt,X/10.0)||X<-lists:seq(1,9)],
    wings_dl:fold(fun(D, _) -> draw_magnet_1(D, R,R2) end, []),
    gl:popAttrib().

draw_magnet_1(#dlo{mirror=Mtx,drag=#drag{mm=Side,pos={X,Y,Z}}}, R,R2) ->
    case Side of
    mirror -> gl:multMatrixf(Mtx);
    original -> ok
    end,
    gl:translatef(X, Y, Z),

    Obj = glu:newQuadric(),
    glu:quadricDrawStyle(Obj, ?GLU_FILL),
    glu:quadricNormals(Obj, ?GLU_SMOOTH),
    glu:sphere(Obj, R, 20, 20),
    glu:deleteQuadric(Obj),
    gl:color4f(0, 0, 1, 0.03),
    lists:foreach(
      fun(R3) ->
          Obj2 = glu:newQuadric(),
          glu:quadricDrawStyle(Obj2, ?GLU_FILL),
          glu:quadricNormals(Obj2, ?GLU_SMOOTH),
          glu:sphere(Obj, R3*R, 20, 20),
          glu:deleteQuadric(Obj2)
      end,R2);

draw_magnet_1(_, _,_) -> [].

mirror_info(#we{mirror=none}) -> {[],none};
mirror_info(#we{mirror=Face}=We) ->
    PlaneNormal = wings_face:normal(Face, We),
    FaceVs = wpa:face_vertices(Face, We),
    Origin = wings_vertex:center(FaceVs, We),
    M0 = e3d_mat:translate(Origin),
    M = e3d_mat:mul(M0, e3d_mat:project_to_plane(PlaneNormal)),
    Flatten = e3d_mat:mul(M, e3d_mat:translate(e3d_vec:neg(Origin))),
    {FaceVs,Flatten}.

mirror_matrix(V, {MirrorVs,Flatten}) ->
    case member(V, MirrorVs) of
    false -> none;
    true -> Flatten
    end.

mirror_constrain(none, Pos) -> Pos;
mirror_constrain(Matrix, Pos) -> e3d_mat:mul_point(Matrix, Pos).

geom_title(geom) ->
    ?__(1,"Geometry");
geom_title({geom,N}) ->
    ?__(2,"Geometry #") ++ integer_to_list(N).
