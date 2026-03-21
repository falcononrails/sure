module BridgeAccount::TypeMappable
  extend ActiveSupport::Concern

  def auto_mapping
    type_values = [
      bridge_account.account_type,
      bridge_account.account_subtype,
      bridge_account.account_category,
      bridge_account.raw_payload&.dig("type"),
      bridge_account.raw_payload&.dig("category")
    ].compact.map { |value| value.to_s.downcase }

    if type_values.any? { |value| value.include?("card") || value.include?("credit") }
      { accountable_type: "CreditCard", subtype: "credit_card" }
    elsif type_values.any? { |value| value.include?("mortgage") }
      { accountable_type: "Loan", subtype: "mortgage" }
    elsif type_values.any? { |value| value.include?("loan") }
      { accountable_type: "Loan", subtype: "other" }
    elsif type_values.any? { |value| value.include?("savings") }
      { accountable_type: "Depository", subtype: "savings" }
    elsif type_values.any? { |value| value.include?("checking") || value.include?("current") || value.include?("payment") }
      { accountable_type: "Depository", subtype: "checking" }
    else
      nil
    end
  end
end
