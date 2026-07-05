use sa_monopoly_domain::tile::SpecialTileKind;
use sa_monopoly_domain::{CardDeckId, GameState};

use crate::cards::{CardService, LotteryService};
use crate::economy::EconomyService;
use crate::events::GameEvent;

pub struct EffectResolver;

impl EffectResolver {
    pub fn resolve_special_tile(
        state: &mut GameState,
        tile_id: &str,
        rng: &mut dyn crate::ports::RngService,
    ) -> Option<GameEvent> {
        let tile = state.board.tile(tile_id)?;
        match &tile.kind {
            sa_monopoly_domain::TileKind::Start => Some(GameEvent::CommandAccepted {
                name: "landed_on_start".to_string(),
            }),
            sa_monopoly_domain::TileKind::Chance => {
                let chance_deck_id = CardDeckId("chance".to_string());
                CardService::draw_card(state, &chance_deck_id, rng)
            }
            sa_monopoly_domain::TileKind::SpecialProperty(kind) => {
                Some(GameEvent::CommandAccepted {
                    name: format!("special_tile:{kind:?}"),
                })
            }
            sa_monopoly_domain::TileKind::CardShop => {
                // Predefined cards available at the card shop (prices known by frontend)
                let cards = vec![
                    "get_out_of_jail".to_string(),
                    "bonus_200".to_string(),
                    "double_rent".to_string(),
                ];
                Some(GameEvent::CardShopList { cards })
            },
            sa_monopoly_domain::TileKind::Lottery => {
                LotteryService::ensure_initialized(state);
                let lottery = state.lottery_state.as_ref().unwrap();
                let jackpot = lottery.effective_jackpot(state.current_turn);
                let ticket_price = sa_monopoly_domain::LotteryState::ticket_price_for_turn(state.current_turn);
                Some(GameEvent::LotteryAvailable {
                    ticket_price,
                    jackpot,
                    next_draw_turn: lottery.next_draw_turn,
                })
            },
            sa_monopoly_domain::TileKind::Bank => {
                // Differentiate based on tile_id:
                //   "tax_1" = Income Tax: pay $200
                //   "tax_2" = Luxury Tax: pay $100
                //   otherwise = Free Parking: receive $200
                let event_name = if tile_id == "tax_1" {
                    if let Some(player) = state.active_player_mut() {
                        player.cash -= 200;
                    }
                    "income_tax_200"
                } else if tile_id == "tax_2" {
                    if let Some(player) = state.active_player_mut() {
                        player.cash -= 100;
                    }
                    "luxury_tax_100"
                } else {
                    if let Some(player) = state.active_player_mut() {
                        player.cash += 200;
                    }
                    "free_parking_200"
                };
                Some(GameEvent::CommandAccepted { name: event_name.to_string() })
            },
            sa_monopoly_domain::TileKind::Jail => {
                if tile_id == "go_to_jail" {
                    let player_id =
                        state.active_player().map(|p| p.id.clone()).unwrap_or_default();
                    // Find the "Jail" tile to send player to
                    let jail_tile_id = state.board.tiles.iter()
                        .find(|t| t.id == "jail" || (t.kind == sa_monopoly_domain::TileKind::Jail && t.id != "go_to_jail"))
                        .map(|t| t.id.clone());
                    if let Some(player) = state.active_player_mut() {
                        player.jail_turns = 3;
                        if let Some(jail_id) = jail_tile_id {
                            player.position = jail_id;
                        }
                    }
                    Some(GameEvent::PlayerSentToJail {
                        player_id,
                        turns: 3,
                    })
                } else {
                    // Just Visiting — no effect
                    Some(GameEvent::CommandAccepted {
                        name: "just_visiting_jail".to_string(),
                    })
                }
            }
            sa_monopoly_domain::TileKind::Hospital => {
                let player_id =
                    state.active_player().map(|p| p.id.clone()).unwrap_or_default();
                if let Some(player) = state.active_player_mut() {
                    player.hospital_turns = 2;
                }
                Some(GameEvent::PlayerSentToHospital {
                    player_id,
                    turns: 2,
                })
            }
            sa_monopoly_domain::TileKind::OrdinaryProperty => {
                let owner_id = state.board.property(tile_id).and_then(|p| p.owner.clone());
                match owner_id {
                    Some(owner) => {
                        let active_player_id = state
                            .active_player()
                            .map(|p| p.id.clone())
                            .unwrap_or_default();
                        // If the player lands on their own property, skip rent and
                        // emit a special event so the turn processor can offer an upgrade.
                        if owner == active_player_id {
                            Some(GameEvent::CommandAccepted {
                                name: "own_property".to_string(),
                            })
                        } else {
                            // Use the actual amount returned by pay_rent (which reflects
                            // any double_rent card doubling), not the static current_rent.
                            let (actual_amount, _card_consumed) =
                                EconomyService::pay_rent(state, tile_id).ok()?;
                            Some(GameEvent::RentPaid {
                                from_player_id: active_player_id,
                                to_player_id: owner,
                                amount: actual_amount,
                            })
                        }
                    }
                    None => Some(GameEvent::CommandAccepted {
                        name: "unowned_property".to_string(),
                    }),
                }
            }
            sa_monopoly_domain::TileKind::ExtensionProperty => None,
        }
    }

    pub fn describe_special(kind: &SpecialTileKind) -> &'static str {
        match kind {
            SpecialTileKind::Opportunity => "opportunity",
            SpecialTileKind::CardShop => "card_shop",
            SpecialTileKind::Lottery => "lottery",
            SpecialTileKind::Bank => "bank",
            SpecialTileKind::Jail => "jail",
            SpecialTileKind::Hospital => "hospital",
        }
    }
}
