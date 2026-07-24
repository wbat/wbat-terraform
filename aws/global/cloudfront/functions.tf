# CloudFront Functions for www.tellerstech.com
#
# Origin Host is origin.tellerstech.com (required; forwarding viewer Host causes
# 502s). Nginx absolute redirects therefore use that host unless we rewrite them
# at the edge. wp-config.php already fixes PHP redirects when the shared secret
# matches; these functions cover nginx-level redirects (e.g. trailing slash).
#
# Max one CloudFront Function per event type per behavior — xmlrpc 403 and
# /wp-admin trailing-slash redirect share this viewer-request function.

resource "aws_cloudfront_function" "wp_admin_trailing_slash" {
  name    = "tellerstech-wp-admin-trailing-slash"
  runtime = "cloudfront-js-2.0"
  comment = "Block xmlrpc.php; redirect /wp-admin → /wp-admin/ on www"
  publish = true
  code    = <<-EOF
function handler(event) {
  var request = event.request;
  var uri = request.uri;

  // WordPress xmlrpc is a common brute-force / amplification vector; never origin.
  if (uri === '/xmlrpc.php' || uri.indexOf('/xmlrpc.php?') === 0) {
    return {
      statusCode: 403,
      statusDescription: 'Forbidden',
      headers: {
        'content-type': { value: 'text/plain' }
      },
      body: 'Forbidden'
    };
  }

  if (uri === '/wp-admin') {
    var location = 'https://www.tellerstech.com/wp-admin/';
    var parts = [];
    Object.keys(request.querystring).forEach(function (key) {
      var q = request.querystring[key];
      if (q.multiValue) {
        q.multiValue.forEach(function (item) {
          parts.push(key + '=' + item.value);
        });
      } else if (q.value) {
        parts.push(key + '=' + q.value);
      } else {
        parts.push(key);
      }
    });
    if (parts.length > 0) {
      location += '?' + parts.join('&');
    }
    return {
      statusCode: 301,
      statusDescription: 'Moved Permanently',
      headers: {
        location: { value: location }
      }
    };
  }
  return request;
}
EOF
}

resource "aws_cloudfront_function" "rewrite_origin_location" {
  name    = "tellerstech-rewrite-origin-location"
  runtime = "cloudfront-js-2.0"
  comment = "Rewrite Location: origin.tellerstech.com → www.tellerstech.com"
  publish = true
  code    = <<-EOF
function handler(event) {
  var response = event.response;
  var headers = response.headers;
  if (!headers.location) {
    return response;
  }
  var loc = headers.location.value;
  if (loc.indexOf('://origin.tellerstech.com') !== -1) {
    headers.location = {
      value: loc.split('://origin.tellerstech.com').join('://www.tellerstech.com')
    };
  } else if (loc.indexOf('://www.origin.tellerstech.com') !== -1) {
    headers.location = {
      value: loc.split('://www.origin.tellerstech.com').join('://www.tellerstech.com')
    };
  }
  return response;
}
EOF
}
