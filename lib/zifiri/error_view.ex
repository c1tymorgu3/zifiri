defmodule Zifiri.ErrorView do
  @moduledoc """
  The endpoint's last resort: a fault answers in the same fixed bucket as every
  other API response.

  Phoenix reaches this view when a plug raises past the router (an oversized
  body, an out-of-range integer handed to the store, a bug). Rendering the
  default error page here would answer with a stack of HTML that names the
  request, the path, and sometimes the input — exactly the reflection the
  surface forbids. Every template below is the same constant text, padded to
  the response bucket, so a 500 is indistinguishable in size from a 200 and
  says nothing about what failed.
  """

  @response_bytes 16_384
  @refused ~s({"error":"refused"})
  @not_found ~s({"error":"not_found"})

  def render("404.html", _assigns), do: padded(@not_found)
  def render("404.json", _assigns), do: padded(@not_found)

  def render(_template, _assigns), do: padded(@refused)

  defp padded(json), do: json <> :binary.copy(" ", @response_bytes - byte_size(json))
end
