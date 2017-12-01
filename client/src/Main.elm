port module Main exposing (..)

import Date.Extra
import EveryDict as Dict
import FeatherIcons
import Html exposing (..)
import Html.Attributes exposing (..)
import Html.Events exposing (..)
import Http
import Json.Decode as D
import Json.Encode as E
import Maybe.Extra
import RemoteData exposing (RemoteData(..), WebData)
import Svg
import Svg.Attributes
import Tachyons exposing (classes, tachyons)
import Tachyons.Classes exposing (..)
import Vote exposing (Vote)
import VoteEvent exposing (VoteEvent)
import Votes exposing (Votes)


-- PORTS --


port chartData : E.Value -> Cmd msg


port personNodeHovered : (Int -> msg) -> Sub msg


port personNodeUnhovered : (Int -> msg) -> Sub msg


port personNodeClicked : (Int -> msg) -> Sub msg



---- MODEL ----


type alias Model =
    { votes : WebData Votes
    , chartVoteId : Maybe Vote.Id
    , voteInput : String
    , hoveredPersonId : Maybe Int
    , selectedPersonId : Maybe Int
    }


init : ( Model, Cmd Msg )
init =
    ( { votes = NotAsked
      , chartVoteId = Nothing
      , voteInput = ""
      , hoveredPersonId = Nothing
      , selectedPersonId = Nothing
      }
    , getInitialVotes
    )


getInitialVotes : Cmd Msg
getInitialVotes =
    Http.get "/votes" Votes.decoder
        |> RemoteData.sendRequest
        |> Cmd.map InitialVotesResponse



---- UPDATE ----


type Msg
    = InitialVotesResponse (WebData Votes)
    | VoteEventsResponse Vote.Id (WebData (List VoteEvent))
    | VoteChanged String
    | ShowVote Vote.Id
    | PersonNodeHovered Int
    | PersonNodeUnhovered Int
    | PersonNodeClicked Int
    | ClearSelectedPerson


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        InitialVotesResponse votes ->
            let
                newModel =
                    { model | votes = votes }
            in
            handleVoteStateChange newModel

        VoteEventsResponse voteId response ->
            case model.votes of
                Success { selected, data } ->
                    let
                        newVotes =
                            Votes selected
                                (Dict.update
                                    voteId
                                    (Maybe.map (\vote -> { vote | voteEvents = response }))
                                    data
                                )
                                |> Success

                        newModel =
                            { model | votes = newVotes }
                    in
                    handleVoteStateChange newModel

                _ ->
                    model ! []

        VoteChanged input ->
            { model | voteInput = input } ! []

        ShowVote newVoteId ->
            case model.votes of
                Success { data } ->
                    let
                        newVotes =
                            Votes newVoteId data |> Success

                        newModel =
                            { model | votes = newVotes }
                    in
                    handleVoteStateChange newModel

                _ ->
                    model ! []

        PersonNodeHovered personId ->
            { model | hoveredPersonId = Just personId } ! []

        PersonNodeUnhovered personId ->
            let
                newModel =
                    if model.hoveredPersonId == Just personId then
                        { model | hoveredPersonId = Nothing }
                    else
                        model
            in
            newModel ! []

        PersonNodeClicked personId ->
            { model | selectedPersonId = Just personId } ! []

        ClearSelectedPerson ->
            { model | selectedPersonId = Nothing } ! []


{-|

    Handle in a standard way updating model and making HTTP requests/sending
    graph data through port, when either selected vote or Votes data changes.

-}
handleVoteStateChange : Model -> ( Model, Cmd Msg )
handleVoteStateChange model =
    case model.votes of
        Success votes ->
            case Votes.selected votes of
                Just vote ->
                    let
                        { previous, next } =
                            Votes.neighbouringVotes votes
                                |> Maybe.withDefault
                                    { previous = Nothing, next = Nothing }

                        maybeCmdToGet =
                            \maybeVote ->
                                Maybe.map cmdToGetEvents maybeVote
                                    |> Maybe.Extra.join

                        neighbouringVotesToGet =
                            Maybe.Extra.values
                                [ maybeCmdToGet previous, maybeCmdToGet next ]
                    in
                    case vote.voteEvents of
                        Success voteEvents ->
                            { model | chartVoteId = Just vote.id }
                                ! (sendChartData vote :: neighbouringVotesToGet)

                        NotAsked ->
                            let
                                newVotesData =
                                    Dict.update
                                        vote.id
                                        (Maybe.map
                                            (\vote -> { vote | voteEvents = Loading })
                                        )
                                        votes.data

                                newVotes =
                                    Votes votes.selected newVotesData |> Success

                                newModel =
                                    { model | votes = newVotes }
                            in
                            newModel ! (getEventsForVote vote.id :: neighbouringVotesToGet)

                        Failure _ ->
                            -- XXX Handle this somewhere?
                            model ! neighbouringVotesToGet

                        Loading ->
                            model ! neighbouringVotesToGet

                Nothing ->
                    model ! []

        _ ->
            model ! []


cmdToGetEvents : Vote -> Maybe (Cmd Msg)
cmdToGetEvents vote =
    if RemoteData.isNotAsked vote.voteEvents then
        getEventsForVote vote.id |> Just
    else
        Nothing


getEventsForVote : Vote.Id -> Cmd Msg
getEventsForVote voteId =
    let
        (Vote.Id id) =
            voteId

        path =
            "/vote-events/" ++ toString id
    in
    Http.get path (D.list VoteEvent.decoder)
        |> RemoteData.sendRequest
        |> Cmd.map (VoteEventsResponse voteId)


sendChartData : Vote -> Cmd msg
sendChartData vote =
    Vote.chartDataValue vote |> chartData



---- VIEW ----


view : Model -> Html Msg
view model =
    case model.votes of
        Success votes ->
            viewVotes model.hoveredPersonId model.selectedPersonId votes

        Failure error ->
            div [] [ "Error loading data: " ++ toString error |> text ]

        NotAsked ->
            div [] []

        Loading ->
            div [] [ text "Loading..." ]


viewVotes : Maybe Int -> Maybe Int -> Votes -> Html Msg
viewVotes hoveredPersonId selectedPersonId votes =
    case ( Votes.selected votes, Votes.neighbouringVotes votes ) of
        ( Just current, Just { previous, next } ) ->
            let
                previousVoteButton =
                    voteNavigationButton previous "<"

                nextVoteButton =
                    voteNavigationButton next ">"

                voteNavigationButton =
                    \maybeVote ->
                        \icon ->
                            case maybeVote of
                                Just { id } ->
                                    button [ onClick (ShowVote id) ] [ text icon ]

                                Nothing ->
                                    span [] []

                currentEventForPersonId =
                    Vote.eventForPersonId current

                hoveredPersonEvent =
                    currentEventForPersonId hoveredPersonId

                selectedPersonEvent =
                    currentEventForPersonId selectedPersonId

                chartClasses =
                    if RemoteData.isLoading current.voteEvents then
                        [ o_70 ]
                    else
                        []

                chart =
                    div [ classes chartClasses ]
                        [ Svg.svg
                            [ width 1000
                            , height 550
                            , id "d3-simulation"
                            , Svg.Attributes.class "db center"
                            ]
                            []
                        ]

                ayeText =
                    voteDescription "Aye" current.actionsYes

                noText =
                    voteDescription "No" current.actionsNo

                absentOrBothText =
                    strong [] [ text "Absent or Both" ]
            in
            section
                [ classes
                    [ vh_100
                    , mw9
                    , center
                    , bg_near_white
                    , pa3
                    , ph5_ns
                    , helvetica
                    , lh_copy
                    , f4
                    ]
                ]
                [ tachyons.css
                , div [ classes [ fl, w_75 ] ]
                    [ div []
                        [ currentVoteInfo current
                        , div [] [ previousVoteButton, nextVoteButton ]
                        ]
                    , div
                        [ classes [ center, mw_100, pt5 ] ]
                        [ chart
                        , div [ classes [ tc ] ]
                            [ span [ classes [ fl, w_40, border_box, pr4 ] ] [ ayeText ]
                            , span [ classes [ fl, w_20 ] ] [ absentOrBothText ]
                            , span [ classes [ fl, w_40, border_box, pl4 ] ] [ noText ]
                            ]
                        ]
                    ]
                , div [ classes [ fl, w_25 ] ]
                    [ div [ classes [ fr ] ]
                        (Maybe.Extra.values
                            [ selectedPersonInfoBox selectedPersonEvent
                            , hoveredPersonInfoBox hoveredPersonEvent
                            ]
                        )
                    ]
                ]

        _ ->
            div [] [ text "No votes available." ]


voteDescription : String -> String -> Html msg
voteDescription vote details =
    let
        details_ =
            String.trim details

        voteHtml =
            strong [] [ text vote ]
    in
    if String.isEmpty details_ then
        voteHtml
    else
        span [] [ voteHtml, " " ++ details_ |> text ]


currentVoteInfo : Vote -> Html msg
currentVoteInfo currentVote =
    div
        [ classes [ Tachyons.Classes.h3 ] ]
        [ "Current vote: "
            ++ currentVote.policyTitle
            ++ " | "
            ++ currentVote.text
            ++ " | "
            ++ Date.Extra.toFormattedString "ddd MMMM, y" currentVote.date
            |> text
        ]


selectedPersonInfoBox : Maybe VoteEvent -> Maybe (Html Msg)
selectedPersonInfoBox =
    maybePersonInfoBox True


hoveredPersonInfoBox : Maybe VoteEvent -> Maybe (Html Msg)
hoveredPersonInfoBox =
    maybePersonInfoBox False


maybePersonInfoBox : Bool -> Maybe VoteEvent -> Maybe (Html Msg)
maybePersonInfoBox showIcons =
    Maybe.map (personInfoBox showIcons)


personInfoBox : Bool -> VoteEvent -> Html Msg
personInfoBox showIcons event =
    let
        colour =
            if VoteEvent.isSpeaker event then
                -- Showing speaker's party colour as black, so show text as
                -- white so can see it.
                white
            else
                black

        lockIcon =
            iconButton left_0
                FeatherIcons.lock
                [ title "Stop tracking"
                , onClick ClearSelectedPerson
                ]

        infoLinkIcon =
            iconButton right_0
                FeatherIcons.externalLink
                [ title "View on TheyWorkForYou"
                , href infoLink
                ]

        infoLink =
            "https://www.theyworkforyou.com/mp/" ++ toString event.personId

        iconButton =
            \position ->
                \icon ->
                    \attributes ->
                        if showIcons then
                            Just
                                (a
                                    ([ classes
                                        [ absolute
                                        , position
                                        , bottom_0
                                        , pa2
                                        , dim
                                        , colour
                                        , pointer
                                        ]
                                     , target "_blank"
                                     ]
                                        ++ attributes
                                    )
                                    [ icon ]
                                )
                        else
                            Nothing
    in
    div
        [ classes
            [ br2
            , bg_white
            , Tachyons.Classes.h5
            , w5
            , f3
            , tc
            , relative
            , colour
            ]
        ]
        (Maybe.Extra.values
            [ Just (personInfo event)
            , lockIcon
            , infoLinkIcon
            ]
        )


personInfo : VoteEvent -> Html msg
personInfo event =
    div
        [ classes [ h_100 ]
        , style [ ( "background-color", VoteEvent.partyColour event ) ]
        ]
        [ div [] [ text event.name ]
        , personImage event
        , div [] [ text event.party ]
        ]


personImage : VoteEvent -> Html msg
personImage event =
    let
        primaryImageUrl =
            imageUrl ".jpeg"

        secondaryImageUrl =
            imageUrl ".jpg"

        imageOnError =
            -- For some reason TWFY images mostly have a `jpeg` extension but
            -- sometimes have `jpg`; if the former fails to load then attempt
            -- to load the latter (see
            -- https://stackoverflow.com/a/92819/2620402).
            String.join ""
                [ "this.onerror=null;this.src='"
                , secondaryImageUrl
                , "';"
                ]

        imageUrl =
            \suffix ->
                String.join ""
                    [ "https://www.theyworkforyou.com/images/mps/"
                    , toString event.personId
                    , suffix
                    ]
    in
    img
        [ src primaryImageUrl
        , height 100
        , attribute "onerror" imageOnError
        ]
        []



---- SUBSCRIPTIONS ----


subscriptions : Model -> Sub Msg
subscriptions model =
    Sub.batch
        [ personNodeHovered PersonNodeHovered
        , personNodeUnhovered PersonNodeUnhovered
        , personNodeClicked PersonNodeClicked
        ]



---- PROGRAM ----


main : Program Never Model Msg
main =
    Html.program
        { view = view
        , init = init
        , update = update
        , subscriptions = subscriptions
        }
