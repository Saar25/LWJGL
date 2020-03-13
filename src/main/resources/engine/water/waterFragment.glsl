/*
    WATER FRAGMENT SHADER
*/
#version 400 core

#define MAX_LIGHTS 10
const float distortionPower = 0.03;
const float specularPower = 50.0;
const float reflectance = 0.30;

const vec3 waterColour = vec3(0.604, 0.867, 0.851);
//const vec3 waterColour = vec3(0.1, 0.4, 0.8);
const float minMurkiness = 0.20;
const float maxMurkiness = 0.55;
const float murkyDepth = 60;
const float edgeSoftness = 10;

struct Light {
    vec3 position;
    vec3 colour;
    bool directional;
    vec3 attenuation;
    float intensity;
};

in vec3 v_position;
in vec2 out_texCoord;
in vec3 out_normal;
in vec4 clipSpace;
in vec3 toCameraVector;

out vec4 fragColour;

uniform sampler2D reflectionTexture;
uniform sampler2D refractionTexture;
uniform sampler2D depthTexture;
uniform sampler2D normalsMap;
uniform sampler2D dudvMap;
uniform int availableTextures;

uniform float distortionOffset;
uniform Light lights[MAX_LIGHTS];
uniform int lightsCount;

uniform float farPlane;
uniform float nearPlane;

int getBit(int number, int bit) {
    return (number >> bit) & 1;
}

bool hasTexture(int unit) {
    return getBit(availableTextures, unit) == 1;
}

float calcAttenuationFactor(vec3 att, vec3 toLightVector) {
    float d = length(toLightVector);
    float attFactor = att.x + att.y * d + att.z * d * d;
    return 1 / attFactor;
}

float calcDiffuseFactor(vec3 normal, vec3 toLight, float intensity) {
    float diffuseFactor = dot(toLight, normal);
    diffuseFactor = max(diffuseFactor, 0.0);
    diffuseFactor *= intensity;
    return diffuseFactor;
}

float calcSpecularFactor(vec3 fromLight, vec3 toCamera, vec3 normal, float reflectance) {
    vec3 reflected = normalize(reflect(fromLight, normal));
    float specularFactor = dot(reflected, toCamera);
    specularFactor = max(specularFactor, 0.0);
    specularFactor = pow(specularFactor, specularPower);
    specularFactor = specularFactor * reflectance;
    return specularFactor;
}

float calcFresnelFactor(vec3 normal, vec3 toCamera) {
    float fresnelFactor = dot(normal, toCamera);
    fresnelFactor = clamp(fresnelFactor, 0, 1);
    fresnelFactor = pow(fresnelFactor, reflectance);
    return fresnelFactor;
}

float calculateMurkiness(float waterDepth) {
    float murkyFactor = smoothstep(0, murkyDepth, waterDepth);
    return minMurkiness + murkyFactor * (maxMurkiness - minMurkiness);
}

float toLinearDepth(float depth) {
    return 2.0 * nearPlane * farPlane / (farPlane + nearPlane -
        (2 * depth - 1) * (farPlane - nearPlane));
}

float calculateWaterDepth(vec2 texCoords) {
    if (hasTexture(2)) {
        float waterDistance = toLinearDepth(gl_FragCoord.z);
        float depth = texture(depthTexture, texCoords).r;
        float floorDistance = toLinearDepth(depth);
        return floorDistance - waterDistance;
    }
    return edgeSoftness / 2;
}

vec2 distorteTexCoord(vec2 texCoord) {
    if (hasTexture(4)) {
        vec2 coords = vec2(texCoord.x + distortionOffset, texCoord.y);
        vec2 distorted = texture(dudvMap, coords).rg * 0.1;
        return texCoord + distorted * (distortionPower + 1);
    }
    return vec2(0);
}

vec2 calculateDistortion(vec2 texCoord, float depthFactor) {
    if (hasTexture(4)) {
        vec2 distortion = texture(dudvMap, texCoord).rg * 2.0 - 1.0;
        return distortion * distortionPower * clamp(depthFactor / 20, 0, 1);
    }
    return vec2(0);
}

vec3 calculateDistortedNormal(vec2 distortedTexCoord) {
    if (hasTexture(3)) {
        vec3 distortedNormal = texture(normalsMap, distortedTexCoord).rbg;
        distortedNormal = distortedNormal * vec3(2, 1.7, 2) - vec3(1, 0, 1);
        return normalize(distortedNormal);
    }
    return out_normal;
}

float coordsShift() {
    return hasTexture(3) ? 0 : v_position.y * 0.01;
}

vec3 calculateReflectionColour(vec2 ndc, vec2 distortion) {
    if (hasTexture(0)) {
        vec2 reflectionCoord = vec2(ndc.x, 1 - ndc.y) + distortion + coordsShift();
        reflectionCoord = clamp(reflectionCoord, 0.001, 0.999);
        return texture(reflectionTexture, reflectionCoord).rgb;
    }
    return waterColour;
}

vec3 calculateRefractionColour(vec2 ndc, vec2 distortion) {
    if (hasTexture(1)) {
        vec2 refractionCoord = ndc + distortion + coordsShift();
        refractionCoord = clamp(refractionCoord, 0.001, 0.999);
        return texture(refractionTexture, refractionCoord).rgb;
    }
    return waterColour;
}

void main(void) {
    vec2 ndc = (clipSpace.xy / clipSpace.w) * 0.5 + 0.5;
    float depthFactor = calculateWaterDepth(ndc);

    vec2 distortedTexCoord = distorteTexCoord(out_texCoord);
    vec3 distortedNormal = calculateDistortedNormal(distortedTexCoord);
    vec2 distortion = calculateDistortion(distortedTexCoord, depthFactor);

    vec3 reflectionColour = calculateReflectionColour(ndc, distortion);
    vec3 refractionColour = calculateRefractionColour(ndc, distortion);

    // Add fresnel effect
    float fresnelFactor = calcFresnelFactor(distortedNormal, normalize(toCameraVector));
    vec3 finalColour = mix(refractionColour, waterColour, calculateMurkiness(depthFactor));
    finalColour = mix(reflectionColour, finalColour, fresnelFactor);

    // Add light
    //vec3 finalDiffuse = vec3(0);
    vec3 finalSpecular = vec3(0);
    for (int i = 0; i < lightsCount; i++) {
        Light light = lights[i];

        vec3 toLightVector = light.directional ? light.position : light.position - v_position;
        float attFactor = calcAttenuationFactor(light.attenuation, toLightVector);
        if (attFactor < 0.05) {
            continue;
        }
        toLightVector = normalize(toLightVector);

        // Specular light
        vec3 fromLight = -toLightVector;
        vec3 toCamera = normalize(toCameraVector);
        float specularFactor = calcSpecularFactor(fromLight, toCamera, distortedNormal, clamp(depthFactor / 20, 0, 1));
        vec3 specularColour = light.colour * specularFactor;

        finalSpecular += attFactor * specularColour;
        //finalDiffuse += calcDiffuseFactor(distortedNormal, toLightVector, light.intensity);
    }

    // Add light, fog and soft edges to the water
    //finalColour = finalColour * finalDiffuse;
    finalColour = finalColour + finalSpecular;

    float softEdge = clamp(depthFactor / edgeSoftness, 0, 1);
    fragColour = vec4(finalColour, softEdge);

}
