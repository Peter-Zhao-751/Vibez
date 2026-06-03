#!/usr/bin/env bash
#
# Generate (or surface) the user's Vibez ID and instructions for
# pairing it with the Vibez iPhone app.
#
# Invoked from the vibez-setup skill.
#
# Args:
#   regenerate    discard the existing ID and create a new one
#   test          POST a test push to the Vibez backend for this ID
#
# Vibez ID format: 4 hyphen-separated common English words, each 3-5
# letters, drawn from a curated ~2000-word list. ~44 bits of entropy,
# enough to make brute-forcing impractical for the threat model
# (anyone who guesses the ID can push to that phone). The Vibez
# app pairs the entered ID with its FCM token via the
# `registerPushToken` Cloud Function on first launch.

set -uo pipefail

CONFIG_DIR="${HOME}/.config/vibez"
ID_FILE="${CONFIG_DIR}/vibez-id"
LEGACY_TOPIC_FILE="${CONFIG_DIR}/topic"
BACKEND_URL="${VIBEZ_BACKEND_URL:-https://us-central1-vibez-backend.cloudfunctions.net}"

# Curated 3-5 letter English words. Kept here so the plugin has no
# external dependency for ID generation. Word count is not a power of
# two — we use rejection sampling below to keep the distribution
# uniform.
WORDS_BLOB='
ace acid acre add age aim air ale all also ant ape apt arc area arid
ark arm army art ash ask atom aunt axis baby back bake ball band bank
bare bark barn base bass bat bath bay beak bean bear beat bed bee bell
belt bend bent best big bike bin bird bit bite black blade blame blank
blast blaze blend bless block blood bloom blow blue blur boat body bog
boil bold bolt bomb bond bone book boom boot bore born boss both bowl
box boy brace braid brain brake brand brass brave bread break brew
brick brief bring brink brisk broad broke brook broom brown brush buck
bug build bulb bulk bull bump bunch burn burst bus bush busy cab cake
calf call calm camp can cane cap cape car card care case cash cast cat
cave cedar cell cent chain chair champ chap chase chat check cheek
cheer chef chest chew chief child chill chime chin chip chop chose
chuck chunk claim clamp clan clap clash class claw clay clean clear
click cliff climb cling clip clock close cloth cloud clown club clue
coach coal coast coat code coil coin cold come comet comic cone cook
cool cope copy coral cord core cork corn cost couch cough count cove
cow crab crack craft crane crank crash crate crawl crazy cream creek
creep crew crib crime crisp crop cross crowd crown crude crumb crush
crust cry cub cube cuff cup curb cure curl curve cute daily dairy daisy
dance dare dark dash data date dawn deal dean deck deed deep deer den
dense dent deny depot derby dial dice dim dime dine dip dirt dish dive
dock doe dog dome done door dose dot dove down doze drag drain drama
draw dread dream dress drift drill drink drip drive drone drop drum
dry duck dude due dull dump dusk dust duty dwarf each early earn ease
east easy ebb echo edge edit eel egg ego elf elk elm end enemy enjoy
enter envy epic equal era erase essay etch even event ever evil exit
eye face fact fade fail faint fair fake fall fame fan far farm fast
fat fate fault fawn fear feat fed fee feed feel fell felt fence fern
ferry few field fight file fill film final find fine fire firm fish
fist fit five fix flag flake flame flap flare flash flat flaw flea
fled flee flesh flew flex flick fling flint flip float flock flood
floor flop flour flow fluid flush flute fly foam fog foil fold folk
food fool foot fork form fort found foyer frame fraud freak free fresh
fret fried frill frog from front frost frown froze fruit fry fuel fume
fund funk fur fury fuss gain gala game gap gas gate gave gaze gear gem
gent germ gift gig gild gin girl give glad glare glass gleam glee
glide glint globe gloom glory glow glue glum goal goat gold golf gone
good goose grab grace grade grain gram grand grant grape graph grasp
grass grate grave gravy gray graze great green greet grew grid grief
grill grim grin grip grit groan groom group grove grow grub gruff
grump grunt guard guest guide guild guilt gulf gull gulp gum gun gush
gust gym hail hair half hall halt hand hang harm harsh hat hatch haul
haunt have hawk hay haze head heal heap hear heart heat hedge heel
heir held help hem hen herb herd here hero hide high hike hill hint
hip hire hiss hit hive hoax hog hold hole holy home honey hood hook
hoop hop hope horn horse hose host hot hour house how howl hub hue
hug huge hull hum human hump hung hunt hurl hurt hush husk hut ice icy
idea idle idol ill imp inch info ink inn input iris iron ivy jab jade
jail jam jar jaw jay jazz jean jeep jelly jet jewel jiffy jig jive job
jog join joint joke jolly jolt jot joy judge juice juicy jumbo jump
junk jury just kale keen keep keg kelp kept key kick kid kind king
kink kiss kit kite kiwi knack knee knelt knew knit knob knock knot
know lab lace lack lad lady lain lair lake lamb lame lamp land lane
lap large lark laser lash last late laud lava law lawn lay layer lazy
lead leaf leak lean leap learn leash least leave led leek left leg
lemon lend lens lent less let level lever lick lid lie life lift light
like lily limb lime limit limp line link lint lion lip list lit live
llama load loaf lobby local lock log logic logo lone long look loom
loop loose loot lord lore lose loss lost loud love low loyal lucid
luck lull lump lung lure lurk lush lute lynx mace magic maid mail
main maker make male mall malt mango manor map maple march mare mark
marry marsh mart mash mask mass mast mat match mate math may maze
meal mean meant meat medic meet melt memo men mend mercy merge merit
merry mesh metal meter mid might mild mile milk mill mind mine mini
mink mint minus miser miss mist mix moan moat mob mock mode model
moist mold mole molt mom money monk month mood moon moor moose mope
moral more morn moss most moth mouse mouth move movie mow much mud
muddy muff mug mule mum munch mural muse mush music must mute mutt
myth nag nail name nap nasty navy near neat neck need nerve nest net
new news next nice niche nick night nine noble nod node noise nomad
noon norm north nose nosy not note noun nova novel now nub nude nuke
null numb nurse nut oak oar oat obey ocean odd odor off often ogre oil
okay old olive omen once one onion only onto onyx ooze opal open oboe
opera opt oral orb organ other otter ounce our out outer oval oven
over owe owl own oxide page paid pail pain paint pair pal pale palm
pan panda pane panic pant papa paper park parka part party pass past
path patio paw pawn pay peach pea peak pearl peck peel peep peer pelt
pen penny perky perm petal piano pick pier pig pike pile pilot pin
pinch pine pink pint pipe pit pivot pizza place plain plan plane
plank plant plate play plaza plead pleat plot plow pluck plug plum
plump plus poach pod poem poet point poke pole polka poll polo pomp
pond pony pool poor pop pope porch pore pork port pose posh post pot
pouch pound pour pout prank pray press pride prim print prior prism
prize probe prone proof prop prose proud prove prune pub puff pull
pulp pulse pump punch pun punk pup pupil purr purse push put quack
quail quake qualm quart queen quest quick quiet quill quilt quirk
quit quiz quote race racy radar radio raft rag rage raid rail rain
raise rake rally ram ramp ranch ran rang range rank rant rapid rare
rash rat rate raven raw ray reach react ready reap rear reek reel
relax relay rely renew rent repay reset rest rhyme rib rice rich ride
ridge rift right rigid rim ring rink riot ripe rise risk rite rival
river road roar roast rob robe robin rock rocky rode rogue roll roman
romp roof rook room root rope rose rosy rot rotor rough round rouse
route row royal rub ruby ruddy rude ruin rule run rung rural rush
rust rusty rut rye sack sad safe saga sage said sail saint sake salad
sale salt same sand sane sang sank sap sash sat sauce save savor savvy
saw say scale scalp scam scan scant scar scare scarf scary scene scent
scoff scold scoop scope score scorn scour scout scrap scrub scuff seal
seam seat seek seem seen self sell semi send sent serve set seven sew
shack shade shaft shake shaky shall shame shape share shark sharp
shave shawl shed sheen sheep sheer shelf shell shift shine shiny ship
shirk shirt shock shoe shone shook shoot shop shore short shot shout
shove show shown shred shrew shrub shrug sick side sigh sight sign
silk silly silo silt since sing sink sip sir siren sit site six size
skate ski skid skill skim skin skip skirt sky slab slack slain slam
slang slant slap slash slate slave sled sleep sleet slept slew slice
slick slide slim slime sling slip slit slob slog slop slope slot
sloth slow slug slum slump slurp slush smack small smart smash smear
smell smelt smile smirk smite smoke smog smug snack snag snail snake
snap snare snarl sneak sneer sniff snip snore snort snout snow snub
snuff snug soak soap soar sob sock soda sofa soft soil sold solid
solo solve some son song soon soot sore sort soup sour south sow span
spank spare spark speak spear speck speed spell spelt spend spent
sperm spice spicy spike spin spine spire spite splat split spoil
spoke spoof spook spool spoon spore sport spot spout spray spree spry
spud spun spur spy squad squat stab stack staff stag stage stain
stair stake stale stalk stall stamp stand stank star stare start
state stay steak steal steam steed steel steep steer stem step stern
stew stick stiff still sting stink stir stoat stock stoic stole stomp
stone stood stool stoop stop store stork storm story stout stove stow
stub stuck stud study stuff stump stun stung stunt style suave sub
such suck suds sue suet sugar suit sulk sum sun sung sunk sure surf
swab swag swam swamp swan swap swarm sway swear sweat sweep sweet
swell swept swift swim swing swirl swish swoop sword swore sworn
syrup tab table tack taco tacky tact tag tail take tale talk tall
tame tan tang tank tap tape tar tarp tart task taste taunt taupe taut
tax taxi tea teach team tear teary teem teen teeth tell ten tend
tense tent term test text than thank that thaw theft them then there
these they thick thief thigh thin thing think third this thorn those
threw throb throw thud thug thumb thump thus tick tide tidy tie tier
tiger tight tile till tilt time timid tin tine tip tire title toad
toast toe tofu toga toil told toll tomb tone tongs tonic took tool
toot top torch tore tort toss total touch tough tour tout tow town
toxic toy trace track trade train trait tramp trap trash trawl tray
tread treat tree trend trial tribe trice trick tried trim trio trip
trite trod troop trot trout truck true trump trunk trust truth try
tub tube tug tulip tuna tune tunic turf turn tusk tutor tweak tweed
tweet twice twin twirl twist two type typo udder ugly ulcer ultra
unfit unify union unit unite untie until unzip upon urge usage use
user uses usual utter vague vain vale value valve van vane vapor vary
vase vast vat vault veer vein veil venom vent verge verse very vest
veto vex vial vice vie view vile villa vine viola viper viral virus
visa visit visor vital vivid vocal vogue voice void volt vote vouch
vowel wad wade wage wagon wail waist wait wake walk wall waltz wand
wane want war ward ware warm warn warp wart wary wash wasp waste
watch water wave wax way weak weary weave wed wedge wee weed week
weep weft weigh weird welt went wept were west wet whack wham wharf
what wheel when where whey which whiff while whim whine whip whirl
whisk whit white whiz who whole whom whose why wick wide wield wife
wig wild wile will wilt wily wimp win wind windy wine wing wink wipe
wire wise wish wisp witch with woke wolf woman won wonky wood woody
woof wool word wore work world worm worry worse worst worth wove wow
wrack wrap wreck wrist write wrong wrote wry yacht yam yank yard yarn
yawn year yeast yell yelp yes yet yew yield yoga yogi yoke yolk you
young your youth yummy zeal zebra zero zest zinc zip zone zoo
'

# One-shot migration from the old claude-ntfy-named directory used by the
# pre-0.9 Claude Code plugin.
OLD_CONFIG_DIR="${HOME}/.config/claude-ntfy"
if [ -d "${OLD_CONFIG_DIR}" ] && [ ! -d "${CONFIG_DIR}" ]; then
    mv "${OLD_CONFIG_DIR}" "${CONFIG_DIR}" 2>/dev/null || true
fi

mkdir -p "${CONFIG_DIR}" 2>/dev/null || true
chmod 700 "${CONFIG_DIR}" 2>/dev/null || true

# Build the words array once. Whitespace-split (newlines + spaces both
# work with default IFS).
read -r -d '' -a WORDS <<<"${WORDS_BLOB}" || true
WORD_COUNT="${#WORDS[@]}"

# Uniform random index in [0, WORD_COUNT). Reads 2 bytes (16 bits) from
# /dev/urandom and rejects values that would bias the modulo.
random_index() {
    local max_unbiased=$(( 65536 - (65536 % WORD_COUNT) ))
    local raw
    while :; do
        raw=$(od -An -N2 -tu2 /dev/urandom | tr -d ' ')
        if [ "${raw}" -lt "${max_unbiased}" ]; then
            printf '%d' "$(( raw % WORD_COUNT ))"
            return
        fi
    done
}

generate_id() {
    local i parts=()
    for i in 1 2 3 4; do
        parts+=("${WORDS[$(random_index)]}")
    done
    local IFS='-'
    printf '%s' "${parts[*]}"
}

read_id() {
    if [ -n "${VIBEZ_ID:-}" ]; then
        printf '%s' "${VIBEZ_ID}"
        return
    fi
    if [ -f "${ID_FILE}" ]; then
        cat "${ID_FILE}" 2>/dev/null | tr -d '[:space:]'
    fi
}

write_id() {
    printf '%s\n' "$1" >"${ID_FILE}"
    chmod 600 "${ID_FILE}" 2>/dev/null || true
    # Old ntfy topic file is no longer used; tidy it up.
    [ -f "${LEGACY_TOPIC_FILE}" ] && rm -f "${LEGACY_TOPIC_FILE}" 2>/dev/null || true
}

ACTION="${1:-show}"

ID="$(read_id)"

case "${ACTION}" in
    regenerate)
        ID="$(generate_id)"
        write_id "${ID}"
        printf 'Generated a new Vibez ID. Update the iOS app with this new one — the old ID no longer reaches your phone.\n\n'
        ;;
    test)
        if [ -z "${ID}" ]; then
            printf 'No Vibez ID configured yet. Run the vibez-setup skill first.\n'
            exit 0
        fi
        body=$(printf '{"vibezId":"%s","title":"vibez test","body":"If you can read this on your phone, the Codex plugin is wired up.","agent":"cx","event":"done","shield":"on"}' "${ID}")
        if curl -fsS --max-time 5 \
            -H "content-type: application/json" \
            -X POST -d "${body}" \
            "${BACKEND_URL}/notify" >/dev/null 2>&1; then
            printf 'Test push sent for Vibez ID %s\n' "${ID}"
        else
            printf 'Test push failed. Check network or backend (%s).\n' "${BACKEND_URL}"
        fi
        exit 0
        ;;
    show|"")
        if [ -z "${ID}" ]; then
            ID="$(generate_id)"
            write_id "${ID}"
            printf 'No Vibez ID was set, so I generated one.\n\n'
        fi
        ;;
    *)
        printf 'Unknown action: %s\n' "${ACTION}"
        printf 'Usage: setup.sh [show|regenerate|test]\n'
        exit 1
        ;;
esac

printf 'Your Vibez ID:\n\n  %s\n\nType it into the "Set up notifications" widget in the Vibez app on your phone and you'\''re done.\n' "${ID}"

exit 0
