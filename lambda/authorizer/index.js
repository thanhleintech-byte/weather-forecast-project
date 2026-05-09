"use strict";

const { SecretsManagerClient, GetSecretValueCommand } = require("@aws-sdk/client-secrets-manager");
const jwt = require("jsonwebtoken");

const secretsClient = new SecretsManagerClient({});

const JWT_ISSUER  = process.env.JWT_ISSUER   || "max-weather";
const JWT_AUDIENCE = process.env.JWT_AUDIENCE || "max-weather-api";
const SECRET_ARN  = process.env.JWT_SECRET_ARN;

// Cache the secret for the Lambda function lifetime to avoid Secrets Manager
// throttling on every request. The secret is rotated externally; a cold start
// always fetches the latest value.
let cachedSecret = null;

async function getSecret() {
  if (cachedSecret) return cachedSecret;
  const cmd = new GetSecretValueCommand({ SecretId: SECRET_ARN });
  const result = await secretsClient.send(cmd);
  cachedSecret = result.SecretString;
  return cachedSecret;
}

/**
 * Build a minimal IAM policy document.
 * @param {string} principalId - Authenticated principal (e.g. client_id from sub)
 * @param {"Allow"|"Deny"} effect
 * @param {string} resource - API Gateway ARN (methodArn or wildcard)
 */
function buildPolicy(principalId, effect, resource) {
  return {
    principalId,
    policyDocument: {
      Version: "2012-10-17",
      Statement: [
        {
          Action: "execute-api:Invoke",
          Effect: effect,
          Resource: resource,
        },
      ],
    },
  };
}

/**
 * Extract the Bearer token from the Authorization header.
 * API Gateway passes the header as `event.authorizationToken` for TOKEN type
 * authorizers, or `event.headers.Authorization` for REQUEST type.
 */
function extractToken(event) {
  const raw =
    event.authorizationToken ||
    (event.headers && (event.headers.Authorization || event.headers.authorization)) ||
    "";
  const match = raw.match(/^Bearer\s+(.+)$/i);
  return match ? match[1] : null;
}

/**
 * Lambda handler — TOKEN-type authorizer for AWS API Gateway.
 */
exports.handler = async (event) => {
  const token = extractToken(event);

  if (!token) {
    console.log(JSON.stringify({ level: "WARN", message: "no_token_provided" }));
    throw new Error("Unauthorized"); // API Gateway returns 401
  }

  let secret;
  try {
    secret = await getSecret();
  } catch (err) {
    console.error(JSON.stringify({ level: "ERROR", message: "secrets_fetch_failed", error: err.message }));
    throw new Error("Unauthorized");
  }

  try {
    const decoded = jwt.verify(token, secret, {
      algorithms: ["HS256"],
      issuer: JWT_ISSUER,
      audience: JWT_AUDIENCE,
    });

    console.log(JSON.stringify({
      level: "INFO",
      message: "token_valid",
      sub: decoded.sub,
    }));

    // Use wildcard so the policy covers all methods/paths in this API
    const resourceArn = event.methodArn
      ? event.methodArn.replace(/\/[^/]+\/[^/]+$/, "/*/*")
      : "*";

    return buildPolicy(decoded.sub, "Allow", resourceArn);
  } catch (err) {
    console.log(JSON.stringify({
      level: "WARN",
      message: "token_invalid",
      reason: err.message,
    }));
    return buildPolicy("anonymous", "Deny", event.methodArn || "*");
  }
};
