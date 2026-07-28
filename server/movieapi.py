import httpx
from fastapi import FastAPI, HTTPException, Request
from pydantic import BaseModel
from typing import List

app = FastAPI(title="EE3 API Daemon")

BASE_URL = "https://ee3.me"
LOGIN_URL = f"{BASE_URL}/login"

USERNAME = "sudoacc3ss"
PASSWORD = "YOUR_PASSWORD_HERE"

# Persistent client to hold cookies automatically
http_client = httpx.AsyncClient(
    base_url=BASE_URL,
    headers={
        "accept": "*/*",
        "accept-language": "en-US,en;q=0.9",
        "user-agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
        "sec-gpc": "1",
    },
    timeout=20.0,
    follow_redirects=True,
)

async def perform_login():
    """Performs the exact SvelteKit form action POST request."""
    form_data = {
        "username": USERNAME,
        "password": PASSWORD
    }
    
    headers = {
        "content-type": "application/x-www-form-urlencoded",
        "origin": BASE_URL,
        "referer": LOGIN_URL,
        # Tells SvelteKit this is a JS-enhanced form submission
        "x-sveltekit-action": "true", 
    }

    try:
        # We post directly to /login (or /login?/default depending on action naming)
        response = await http_client.post(LOGIN_URL, data=form_data, headers=headers)
        
        # Check if we got the standard SvelteKit redirect payload or cookie setting
        if response.status_code == 200 and '"type":"redirect"' in response.text:
            print("Successfully authenticated! Session cookie stored.")
            return True
        elif response.status_code in [200, 302, 303]:
            print("Login successful.")
            return True
        else:
            print(f"Login failed [{response.status_code}]: {response.text}")
            return False
            
    except Exception as e:
        print(f"Error executing login request: {e}")
        return False

@app.on_event("startup")
async def startup():
    await perform_login()

@app.on_event("shutdown")
async def shutdown():
    await http_client.aclose()

# --- API Routes ---

@app.get("/movies")
async def get_movies(request: Request):
    """
    Proxies requests with full query params:
    e.g., http://localhost:8000/movies?sort=-tmdb_data.release_date&min_vote_count=10&page=1&perPage=50
    """
    params = dict(request.query_params)
    response = await http_client.get("/api/movies", params=params)
    
    # Auto re-login if cookie expired mid-session
    if response.status_code in [401, 403]:
        print("Session expired. Attempting re-authentication...")
        if await perform_login():
            response = await http_client.get("/api/movies", params=params)

    if response.status_code != 200:
        raise HTTPException(
            status_code=response.status_code, 
            detail=f"Upstream site error: {response.text}"
        )

    return response.json()


class StreamResolveRequest(BaseModel):
    movie_ids: List[str]


@app.post("/stream/resolve")
async def resolve_stream(payload: StreamResolveRequest):
    """
    Sends PATCH /api/list/{id} to extract stream link
    """
    if not payload.movie_ids:
        raise HTTPException(status_code=400, detail="movie_ids list cannot be empty")

    target_id = payload.movie_ids[0]
    
    custom_headers = {
        "content-type": "application/json",
        "referrer": f"{BASE_URL}/movies/{target_id}",
        "sec-fetch-dest": "empty",
        "sec-fetch-mode": "cors",
        "sec-fetch-site": "same-origin",
    }

    body = {
        "movies": payload.movie_ids
    }

    response = await http_client.patch(
        f"/api/list/{target_id}", 
        json=body, 
        headers=custom_headers
    )

    if response.status_code in [401, 403]:
        print("Session expired during stream resolution. Retrying login...")
        if await perform_login():
            response = await http_client.patch(
                f"/api/list/{target_id}", 
                json=body, 
                headers=custom_headers
            )

    if response.status_code not in [200, 201]:
        raise HTTPException(
            status_code=response.status_code, 
            detail=f"Failed to fetch stream URL: {response.text}"
        )

    return response.json()

if __name__ == "__main__":
    import uvicorn
    uvicorn.run("server:app", host="0.0.0.0", port=8000, reload=True)