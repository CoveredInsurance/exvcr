if Code.ensure_loaded?(Finch) do
  defmodule ExVCR.Adapter.Finch.Converter do
    @moduledoc """
    Provides helpers to mock Finch methods.
    """

    use ExVCR.Converter

    alias ExVCR.Util

    defp string_to_response(string) do
      response = Enum.map(string, fn {x, y} -> {String.to_atom(x), y} end)
      response = struct(ExVCR.Response, response)

      response =
        if response.type == "error" do
          body = string_to_error_reason(response.body)
          %{response | body: body}
        else
          response
        end

      response =
        if is_map(response.headers) do
          headers =
            response.headers
            |> Map.to_list()
            |> Enum.map(fn {k, v} -> {k, v} end)

          %{response | headers: headers}
        else
          response
        end

      response
    end

    # The recorded reason is the `Macro.to_string/1` output of an Elixir term.
    # Cassette contents are untrusted, so rebuild the term from its parsed AST
    # instead of evaluating it: only literal data shapes are accepted, and any
    # call, variable, or other executable form is rejected.
    defp string_to_error_reason(reason) do
      case Code.string_to_quoted(reason) do
        {:ok, quoted} ->
          quoted_to_term(quoted)

        {:error, _} ->
          raise ArgumentError,
                "cassette error reason is not a valid Elixir term: #{inspect(reason)}"
      end
    end

    defp quoted_to_term(literal)
         when is_atom(literal) or is_number(literal) or is_binary(literal),
         do: literal

    defp quoted_to_term(list) when is_list(list), do: Enum.map(list, &quoted_to_term/1)

    defp quoted_to_term({left, right}), do: {quoted_to_term(left), quoted_to_term(right)}

    defp quoted_to_term({:{}, _, elements}) when is_list(elements),
      do: elements |> Enum.map(&quoted_to_term/1) |> List.to_tuple()

    defp quoted_to_term({:%{}, _, pairs}) when is_list(pairs),
      do: Map.new(pairs, &quoted_to_pair/1)

    defp quoted_to_term({:%, _, [module, {:%{}, _, pairs}]}) when is_list(pairs) do
      case quoted_to_term(module) do
        name when is_atom(name) -> struct!(name, Enum.map(pairs, &quoted_to_pair/1))
        _ -> unsupported_error_reason(module)
      end
    end

    defp quoted_to_term({:__aliases__, _, parts} = quoted) when is_list(parts) do
      if Enum.all?(parts, &is_atom/1) do
        Module.concat(parts)
      else
        unsupported_error_reason(quoted)
      end
    end

    defp quoted_to_term({:-, _, [number]}) when is_number(number), do: -number

    defp quoted_to_term({:sigil_c, _, [{:<<>>, _, [string]}, []]}) when is_binary(string),
      do: String.to_charlist(string)

    defp quoted_to_term({:<<>>, _, segments} = quoted) when is_list(segments) do
      if Enum.all?(segments, &(is_binary(&1) or (is_integer(&1) and &1 in 0..255))) do
        IO.iodata_to_binary(segments)
      else
        unsupported_error_reason(quoted)
      end
    end

    defp quoted_to_term(quoted), do: unsupported_error_reason(quoted)

    defp quoted_to_pair({key, value}), do: {quoted_to_term(key), quoted_to_term(value)}
    defp quoted_to_pair(quoted), do: unsupported_error_reason(quoted)

    defp unsupported_error_reason(quoted) do
      raise ArgumentError,
            "cassette error reason must be a literal term, got: #{Macro.to_string(quoted)}"
    end

    defp request_to_string([request, finch_module]) do
      request_to_string([request, finch_module, []])
    end

    defp request_to_string([request, _finch_module, opts]) do
      url =
        Util.build_url(request.scheme, request.host, request.path, request.port, request.query)

      %ExVCR.Request{
        url: parse_url(url),
        headers: parse_headers(request.headers),
        method: String.downcase(request.method),
        body: parse_request_body(request.body),
        options: parse_options(sanitize_options(opts))
      }
    end

    # If option value is tuple, make it as list, for encoding as json.
    defp sanitize_options(options) do
      Enum.map(options, fn {key, value} ->
        if is_tuple(value) do
          {key, Tuple.to_list(value)}
        else
          {key, value}
        end
      end)
    end

    defp response_to_string({:ok, %Finch.Response{} = response}), do: response_to_string(response)

    defp response_to_string(%Finch.Response{} = response) do
      %ExVCR.Response{
        type: "ok",
        status_code: response.status,
        headers: parse_headers(response.headers),
        body: to_string(response.body)
      }
    end

    defp response_to_string({:error, reason}) do
      %ExVCR.Response{
        type: "error",
        body: error_reason_to_string(reason)
      }
    end

    defp error_reason_to_string(reason), do: Macro.to_string(reason)
  end
end
