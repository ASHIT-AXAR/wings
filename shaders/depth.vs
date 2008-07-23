// $Id$
// Depth

varying vec3 DepthColor;

void main()
{
	float DepthNear = -1.0;
	float DepthFar = 1.0;
	vec3 ecPos = vec3(gl_ModelViewMatrix * gl_Vertex);
	vec3 EyeDir = normalize(-ecPos);
	vec3 offset = gl_Vertex.xyz/gl_Vertex.w;
	float z = dot(offset, EyeDir);
	z = (z-DepthNear) / (DepthFar-DepthNear);
	DepthColor = vec3(z);
	#ifdef __GLSL_CG_DATA_TYPES // Fix clipping for Nvidia and ATI
	gl_ClipVertex = gl_ModelViewMatrix * gl_Vertex;
	#endif
	gl_Position = ftransform();
}
