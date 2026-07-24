# CloudFront Functions for www.tellerstech.com
#
# Origin Host is origin.tellerstech.com (required; forwarding viewer Host causes
# 502s). Nginx absolute redirects therefore use that host unless we rewrite them
# at the edge. wp-config.php already fixes PHP redirects when the shared secret
# matches; these functions cover nginx-level redirects (e.g. trailing slash).

resource "aws_cloudfront_function" "wp_admin_trailing_slash" {
  name    = "tellerstech-wp-admin-trailing-slash"
  runtime = "cloudfront-js-2.0"
  comment = "Redirect /wp-admin → /wp-admin/ on www before nginx Host-based 301"
  publish = true
  code    = <<-EOF
function handler(event) {
  var request = event.request;
  if (request.uri === '/wp-admin') {
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
