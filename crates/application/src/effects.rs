use sa_monopoly_domain::tile::SpecialTileKind;
use sa_monopoly_domain::{CardDeckId, GameState, LotteryRuleSet};

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
                let lottery_rules = LotteryRuleSet {
                    enabled: true,
                    ticket_price: 50,
                };
                Some(LotteryService::buy_ticket(state, &lottery_rules, rng))
            },
            sa_monopoly_domain::TileKind::Bank => {
                if let Some(player) = state.active_player_mut() {
                    player.cash += 200;
                }
                Some(GameEvent::CommandAccepted { name: "bank_deposit_200".to_string() })
            },
            sa_monopoly_domain::TileKind::Jail => {
                let player_id =
                    state.active_player().map(|p| p.id.clone()).unwrap_or_default();
                if let Some(player) = state.active_player_mut() {
                    player.jail_turns = 3;
                }
                Some(GameEvent::PlayerSentToJail {
                    player_id,
                    turns: 3,
                })
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
                        // Use the actual amount returned by pay_rent (which reflects
                        // any double_rent card doubling), not the static current_rent.
                        let (actual_amount, _card_consumed) =
                            EconomyService::pay_rent(state, tile_id).ok()?;
                        Some(GameEvent::RentPaid {
                            from_player_id: state
                                .active_player()
                                .map(|p| p.id.clone())
                                .unwrap_or_default(),
                            to_player_id: owner,
                            amount: actual_amount,
                        })
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
