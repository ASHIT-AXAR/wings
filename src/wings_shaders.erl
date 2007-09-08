%%
%%  wings_shaders.erl --
%%
%%     Support for vertex & fragment shaders (for cards with OpenGL 2.0)
%%
%%  Copyright (c) 2001-2006 Bjorn Gustavsson
%%
%%  See the file "license.terms" for information on usage and redistribution
%%  of this file, and for a DISCLAIMER OF ALL WARRANTIES.
%%
%%     $Id$
%%

-module(wings_shaders).
-export([init/0, branding/0]).

-define(NEED_OPENGL, 1).
-include("wings.hrl").
-include("e3d_image.hrl").

init() ->
    Programs = {hemi(),
		%make_prog("hemilight"),
		make_prog("gooch"),
		make_prog("toon"),
		make_prog("brick"),
		make_prog_envmap(),
		make_prog("vertex_color", "Flag", 0), % Use Vertex Normals
		make_prog("vertex_color", "Flag", 1), % Use Face Normals
		make_prog("spherical_ao"),
		make_prog("depth"),
		make_prog("harmonics", "Type", 5),
		make_prog("harmonics", "Type", 8),
		make_prog("harmonics", "Type", 9)},
    ?CHECK_ERROR(),
    gl:useProgram(0),
    put(light_shaders, Programs),
    case wings_pref:get_value(number_of_shaders) > size(Programs) of
	true -> wings_pref:set_value(number_of_shaders, 1);
	false -> ok
    end,
    io:format("Using GPU shaders.\n").

read_texture(FileName) ->
    Path = filename:join(wings_util:lib_dir(wings), "textures"),
    NewFileName = filename:join(Path, FileName),
    ImgRec = e3d_image:load(NewFileName, [{order,lower_left}]),
    ImgRec.

read_shader(FileName) ->
    Path = filename:join(wings_util:lib_dir(wings), "shaders"),
    NewFileName = filename:join(Path, FileName),
    {ok,Bin} = file:read_file(NewFileName),
    Bin.

branding() ->
    wings_io:ortho_setup(),
    {WinW,WinH} = wings_wm:win_size(),
    ImgRec = read_texture("brand.png"),
    #e3d_image{width=ImgW,height=ImgH,image=ImgData} = ImgRec,
    Pad = 2,
    gl:rasterPos2i(WinW-ImgW-Pad, WinH-Pad),
    gl:enable(?GL_BLEND),
    gl:blendFunc(?GL_SRC_ALPHA, ?GL_ONE_MINUS_SRC_ALPHA),
    gl:drawPixels(ImgW, ImgH, ?GL_RGBA, ?GL_UNSIGNED_BYTE, ImgData),
    %%gl:disable(?GL_BLEND), %% Causes think lines on border
    ok.

make_prog_envmap() ->
    Shv = wings_gl:compile(vertex,   read_shader("envmap.vs")),
    Shf = wings_gl:compile(fragment, read_shader("envmap.fs")),
    Prog = wings_gl:link_prog([Shv,Shf]),
    gl:useProgram(Prog),
    FileName = "grandcanyon.png",
    EnvImgRec = read_texture(FileName),
    #e3d_image{width=ImgW,height=ImgH,image=ImgData} = EnvImgRec,
    TxId = 0, %[TxId] = gl:genTextures(1),
    gl:bindTexture(?GL_TEXTURE_2D, TxId),
    gl:texParameteri(?GL_TEXTURE_2D, ?GL_TEXTURE_WRAP_S, ?GL_REPEAT),
    gl:texParameteri(?GL_TEXTURE_2D, ?GL_TEXTURE_WRAP_T, ?GL_REPEAT),
    gl:texParameteri(?GL_TEXTURE_2D, ?GL_TEXTURE_MAG_FILTER, ?GL_LINEAR),
    gl:texParameteri(?GL_TEXTURE_2D, ?GL_TEXTURE_MIN_FILTER, ?GL_LINEAR),
    gl:texImage2D(?GL_TEXTURE_2D, 0, ?GL_RGB, ImgW, ImgH, 0, ?GL_RGB,
		  ?GL_UNSIGNED_BYTE, ImgData),
    gl:activeTexture(?GL_TEXTURE0),
    gl:bindTexture(?GL_TEXTURE_2D, TxId),
    wings_gl:set_uloc(Prog, "EnvMap", TxId),
    Prog.

make_prog(Name) ->
    Shv = wings_gl:compile(vertex, read_shader(Name ++ ".vs")),
    Shf = wings_gl:compile(fragment, read_shader(Name ++ ".fs")),
    Prog = wings_gl:link_prog([Shv,Shf]),
    gl:useProgram(Prog),
    Prog.

make_prog(Name, Var, Val) ->
    Shv = wings_gl:compile(vertex, read_shader(Name ++ ".vs")),
    Shf = wings_gl:compile(fragment, read_shader(Name ++ ".fs")),
    Prog = wings_gl:link_prog([Shv,Shf]),
    gl:useProgram(Prog),
    wings_gl:set_uloc(Prog, Var, Val),
    Prog.

hemi() ->
    Sh = wings_gl:compile(vertex, light_shader_src()),
    Prog = wings_gl:link_prog([Sh]),
    gl:useProgram(Prog),
    wings_pref:set_default(hl_lightpos, {3.0,10.0,1.0}),
    wings_pref:set_default(hl_skycol, {0.95,0.95,0.90}),
    wings_pref:set_default(hl_groundcol, {0.026,0.024,0.021}),
    wings_gl:set_uloc(Prog, "LightPosition", wings_pref:get_value(hl_lightpos)),
    wings_gl:set_uloc(Prog, "SkyColor", wings_pref:get_value(hl_skycol)),
    wings_gl:set_uloc(Prog, "GroundColor", wings_pref:get_value(hl_groundcol)),
    Prog.

light_shader_src() ->
    <<"
       uniform vec3 LightPosition;
       uniform vec3 SkyColor;
       uniform vec3 GroundColor;

       void main()
       {
	   vec3 ecPosition = vec3(gl_ModelViewMatrix * gl_Vertex);
	   vec3 tnorm	   = normalize(gl_NormalMatrix * gl_Normal);
	   vec3 lightVec   = normalize(LightPosition - ecPosition);
	   float costheta  = dot(tnorm, lightVec);
	   float a	   = 0.5 + 0.5 * costheta;
			     // ATI needs this for vcolors to work
	   vec4 color	   = gl_FrontMaterial.diffuse * gl_Color;
	   gl_FrontColor   = color * vec4(mix(GroundColor, SkyColor, a), 1.0);
	   gl_TexCoord[0]  = gl_MultiTexCoord0;
	   gl_Position	   = ftransform();
       }
       ">>.
