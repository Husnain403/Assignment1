"""
UniEvent - University Event Management System
Flask application that fetches events from Ticketmaster Discovery API
and displays them as "University Events" on the UniEvent platform.

Architecture:
- Runs on EC2 instances inside private subnets
- Sits behind an Application Load Balancer (public-facing)
- Fetches event data from external Open API (Ticketmaster)
- Optionally caches event poster images to S3 via boto3
"""

import os
import socket
from datetime import datetime
from flask import Flask
import requests
import boto3
from botocore.exceptions import ClientError

app = Flask(__name__)

TICKETMASTER_API_KEY = os.environ.get("TM_KEY", "")
S3_BUCKET = os.environ.get("S3_BUCKET", "")
TICKETMASTER_URL = "https://app.ticketmaster.com/discovery/v2/events.json"

s3 = boto3.client("s3") if S3_BUCKET else None


def fetch_events(size=12):
    """Pull events from the Ticketmaster Discovery API."""
    params = {"apikey": TICKETMASTER_API_KEY, "size": size}
    response = requests.get(TICKETMASTER_URL, params=params, timeout=10)
    response.raise_for_status()
    return response.json().get("_embedded", {}).get("events", [])


def cache_poster_to_s3(event_id, image_url):
    """Download an event poster and persist it to the encrypted S3 bucket."""
    if not s3 or not image_url:
        return None
    key = f"posters/{event_id}.jpg"
    try:
        s3.head_object(Bucket=S3_BUCKET, Key=key)
        return key
    except ClientError:
        pass
    img = requests.get(image_url, timeout=10).content
    s3.put_object(
        Bucket=S3_BUCKET,
        Key=key,
        Body=img,
        ContentType="image/jpeg",
        ServerSideEncryption="AES256",
    )
    return key


def render_page(events):
    hostname = socket.gethostname()
    cards = []
    for event in events:
        name = event.get("name", "Untitled Event")
        date = event.get("dates", {}).get("start", {}).get("localDate", "TBA")
        venues = event.get("_embedded", {}).get("venues", [{}])
        venue = venues[0].get("name", "TBA") if venues else "TBA"
        images = event.get("images", [])
        image_url = images[0].get("url", "") if images else ""
        info = event.get("info", "Official university event")

        if S3_BUCKET and image_url:
            try:
                cache_poster_to_s3(event.get("id", ""), image_url)
            except Exception:
                pass

        cards.append(f"""
        <div class="event-card">
          <img src="{image_url}" alt="poster">
          <h3>{name}</h3>
          <p><b>Date:</b> {date}</p>
          <p><b>Venue:</b> {venue}</p>
          <p>{info}</p>
        </div>""")

    return f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>UniEvent - University Events</title>
  <style>
    body {{ font-family: Arial, sans-serif; max-width: 1100px; margin: auto;
            padding: 20px; background: #f4f6fa; color: #222; }}
    header {{ background: #003366; color: white; padding: 20px; border-radius: 8px;
              text-align: center; }}
    h1 {{ margin: 0; }}
    .event-card {{ background: white; padding: 15px; margin: 14px 0;
                   border-radius: 8px; box-shadow: 0 2px 6px #ccc; overflow: auto; }}
    .event-card img {{ max-width: 200px; float: right; margin-left: 15px;
                       border-radius: 6px; }}
    footer {{ text-align: center; color: #666; margin-top: 30px; font-size: 13px; }}
  </style>
</head>
<body>
  <header>
    <h1>UniEvent</h1>
    <p>Official University Events Portal</p>
  </header>
  <h2>University Events</h2>
  {''.join(cards)}
  <footer>
    Served by instance <code>{hostname}</code> &middot;
    Last refreshed {datetime.utcnow().isoformat()}Z
  </footer>
</body>
</html>"""


@app.route("/")
def home():
    try:
        events = fetch_events()
        return render_page(events)
    except Exception as ex:
        return f"<h1>UniEvent</h1><p>Could not load events: {ex}</p>", 200


@app.route("/health")
def health():
    return "OK", 200


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=80)
